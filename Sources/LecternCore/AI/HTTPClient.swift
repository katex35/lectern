import Foundation

/// One server-sent event.
struct ServerSentEvent: Equatable, Sendable {
    var event: String?
    var data: String
}

/// Turns the lines of a `text/event-stream` into events
/// (https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation).
struct SSEParser {
    private var event: String?
    private var data: [String] = []

    /// Feeds one line without its line break; returns the event a blank line completes.
    mutating func feed(_ line: String) -> ServerSentEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring = ""
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    /// The stream ended: complete lines still waiting for their blank line make a last event.
    mutating func finish() -> ServerSentEvent? { dispatch() }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            event = nil
            data = []
        }
        guard !data.isEmpty else { return nil }
        return ServerSentEvent(event: event, data: data.joined(separator: "\n"))
    }
}

/// Maps a failed HTTP response to a provider error.
typealias ErrorMapper = @Sendable (_ status: Int, _ body: Data, _ response: HTTPURLResponse) -> ProviderError

struct HTTPClient: Sendable {
    var session: URLSession

    func data(_ request: URLRequest, errors: ErrorMapper) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw errors(http.statusCode, data, http) }
        return data
    }

    func json<T: Decodable>(_ type: T.Type, _ request: URLRequest, errors: ErrorMapper) async throws -> T {
        let body = try await data(request, errors: errors)
        do {
            return try JSONDecoder().decode(T.self, from: body)
        } catch {
            throw ProviderError.invalidResponse("Unexpected answer from \(request.url?.host ?? "server"): \(error)")
        }
    }

    /// Opens an event stream and hands each event to `handle` until it returns false or the stream
    /// ends. An error status is read in full and mapped before any event.
    func events(_ request: URLRequest, errors: ErrorMapper, _ handle: (ServerSentEvent) throws -> Bool) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.transportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse("No HTTP response") }
        guard http.statusCode == 200 else {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 1 << 20 { break }
                }
            } catch {
                // the status already says what went wrong
            }
            throw errors(http.statusCode, body, http)
        }
        var parser = SSEParser()
        var line: [UInt8] = []
        do {
            for try await byte in bytes {
                guard byte == 0x0A else {
                    line.append(byte)
                    continue
                }
                if line.last == 0x0D { line.removeLast() }
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if let event = parser.feed(text), try !handle(event) { return }
            }
        } catch let error as ProviderError {
            throw error
        } catch {
            throw Self.transportError(error)
        }
        // a last line without its line break may be cut off, so only complete lines count
        if let event = parser.finish() { _ = try handle(event) }
    }

    static func transportError(_ error: Error) -> Error {
        if error is CancellationError || error is ProviderError { return error }
        if let url = error as? URLError {
            if url.code == .cancelled { return CancellationError() }
            return ProviderError.network(url.localizedDescription)
        }
        return ProviderError.network(error.localizedDescription)
    }
}

/// Reading error bodies, which every provider shapes a little differently.
enum HTTPErrors {
    static func object(_ body: Data) -> [String: Any]? {
        let json = try? JSONSerialization.jsonObject(with: body)
        if let object = json as? [String: Any] { return object }
        // Gemini wraps streamed errors in an array
        if let array = json as? [Any], let first = array.first as? [String: Any] { return first }
        return nil
    }

    /// `error.message`, `error_description`, `detail` or `message`; otherwise the start of the body.
    static func message(_ body: Data) -> String {
        if let object = object(body) {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            for key in ["error_description", "detail", "message", "error"] {
                if let text = object[key] as? String { return text }
            }
        }
        let text = String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No details" : text
    }

    /// `error.code`, `error.type` or `error.status` (whichever is text), or a plain `error` string.
    static func code(_ body: Data) -> String? {
        guard let object = object(body) else { return nil }
        if let error = object["error"] as? [String: Any] {
            for key in ["code", "type", "status"] {
                if let code = error[key] as? String { return code }
            }
            return nil
        }
        return object["error"] as? String ?? object["code"] as? String
    }

    static func retryAfter(_ response: HTTPURLResponse) -> Double? {
        response.value(forHTTPHeaderField: "retry-after").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Appends the request id the provider's support asks for, when there is one.
    static func message(_ message: String, requestID header: String, in response: HTTPURLResponse) -> String {
        guard let id = response.value(forHTTPHeaderField: header), !id.isEmpty else { return message }
        return "\(message) (request \(id))"
    }

    static func byStatus(_ status: Int, _ message: String, retryAfter: Double?) -> ProviderError {
        switch status {
        case 401: return .unauthorized(message)
        case 402: return .usageLimit(message)
        case 403: return .forbidden(message)
        case 429: return .rateLimited(retryAfter: retryAfter, message)
        case 408, 409, 500...599: return .unavailable(message)
        default: return .invalidRequest(message)
        }
    }
}

private let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// Percent-encodes everything but the unreserved characters (RFC 3986), as OAuth expects.
func formEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
}

extension URLRequest {
    mutating func setJSON<T: Encodable>(_ value: T) throws {
        httpMethod = "POST"
        setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        httpBody = try encoder.encode(value)
    }

    mutating func setForm(_ fields: [(String, String)]) {
        httpMethod = "POST"
        setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        httpBody = Data(fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode<S: StringProtocol>(_ text: S) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
