import Foundation

/// Answers URLSession requests from a handler instead of the network. One handler at a time; the
/// XCTest classes using it run their tests one after another.
final class MockHTTP: URLProtocol {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = [:]
        /// Delivered one by one, to exercise lines split across reads.
        var chunks: [Data] = []
        /// Drop the connection after the chunks instead of finishing cleanly.
        var dropAfterChunks = false

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a },
                  chunks: [Data(text.utf8)])
        }

        /// An event stream, cut into pieces of `pieceSize` bytes.
        static func events(_ text: String, pieceSize: Int = 7, drop: Bool = false) -> Reply {
            let data = Data(text.utf8)
            let chunks = stride(from: 0, to: data.count, by: pieceSize).map { data[$0..<min($0 + pieceSize, data.count)] }
            return Reply(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: chunks.map { Data($0) },
                         dropAfterChunks: drop)
        }
    }

    struct Recorded {
        var request: URLRequest
        var body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }

        var form: [String: String] {
            var fields: [String: String] = [:]
            for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                fields[kv[0]] = kv.count > 1 ? kv[1] : ""
            }
            return fields
        }

        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
    }

    typealias Handler = @Sendable (Recorded) throws -> Reply

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recorded: [Recorded] = []

    /// A session whose requests all go to `handler`.
    static func session(_ handler: @escaping Handler) -> URLSession {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [Recorded] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let entry = Recorded(request: request, body: Self.body(of: request))
        let handler = Self.lock.withLock { () -> Handler? in
            Self.recorded.append(entry)
            return Self.handler
        }
        do {
            guard let handler else { throw URLError(.cannotConnectToHost) }
            let reply = try handler(entry)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
            if reply.dropAfterChunks {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// `event: name` + `data: json` blocks, the way the Anthropic and OpenAI streams write them.
func sse(_ events: [(String?, String)]) -> String {
    events.map { name, data in (name.map { "event: \($0)\n" } ?? "") + "data: \(data)\n\n" }.joined()
}
