import Foundation

/// Gemini through the Gemini API with a Google AI Studio key.
public struct GeminiProvider: LanguageModelProvider {
    public let kind = ProviderKind.gemini
    let apiKey: String
    let baseURL: URL
    let http: HTTPClient

    public init(apiKey: String, baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
                session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = HTTPClient(session: session)
    }

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // in a header, never in the URL
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    // MARK: - models

    struct ModelPage: Decodable {
        struct Model: Decodable {
            var name: String
            var displayName: String?
            var inputTokenLimit: Int?
            var outputTokenLimit: Int?
            var supportedGenerationMethods: [String]?
        }

        var models: [Model]?
        var nextPageToken: String?
    }

    public func models() async throws -> [ModelInfo] {
        var models: [ModelInfo] = []
        var token: String?
        repeat {
            var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
                + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let page = try await http.json(ModelPage.self, request(components.url!), errors: Self.error)
            for model in page.models ?? [] {
                let id = model.name.hasPrefix("models/") ? String(model.name.dropFirst(7)) : model.name
                guard Self.isTextModel(id), model.supportedGenerationMethods?.contains("generateContent") != false else { continue }
                models.append(ModelInfo(id: id, name: model.displayName, contextTokens: model.inputTokenLimit,
                                        maxOutputTokens: model.outputTokenLimit))
            }
            token = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
        } while token != nil
        return models
    }

    /// Text-writing Gemini models; speech, image and embedding models are left out.
    static func isTextModel(_ id: String) -> Bool {
        let excluded = ["tts", "image", "embedding", "live", "native-audio", "aqa"]
        return id.hasPrefix("gemini") && !excluded.contains { id.contains($0) }
    }

    // MARK: - generation

    struct Body: Encodable {
        struct Part: Encodable {
            var text: String
        }

        struct Content: Encodable {
            var role: String?
            var parts: [Part]
        }

        struct Config: Encodable {
            var maxOutputTokens: Int?
        }

        var systemInstruction: Content?
        var contents: [Content]
        var generationConfig: Config?
    }

    struct Chunk: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                var parts: [Part]?
            }

            struct Part: Decodable {
                var text: String?
                var thought: Bool?
            }

            var content: Content?
            var finishReason: String?
        }

        struct Feedback: Decodable {
            var blockReason: String?
        }

        struct Usage: Decodable {
            var promptTokenCount: Int?
            var candidatesTokenCount: Int?
            var thoughtsTokenCount: Int?
        }

        var candidates: [Candidate]?
        var promptFeedback: Feedback?
        var usageMetadata: Usage?
        var modelVersion: String?
    }

    static let refusalReasons: Set<String> = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY"]

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        let http = self.http
        let model = request.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", ":"]))
            ?? request.model
        var urlRequest = self.request(URL(string: "\(baseURL.absoluteString)/models/\(model):streamGenerateContent?alt=sse")!)
        let body = Body(
            systemInstruction: request.system.isEmpty ? nil : Body.Content(parts: [Body.Part(text: request.system)]),
            contents: request.messages.map {
                Body.Content(role: $0.role == .user ? "user" : "model", parts: [Body.Part(text: $0.text)])
            },
            generationConfig: request.maxOutputTokens.map { Body.Config(maxOutputTokens: $0) })
        do {
            try urlRequest.setJSON(body)
        } catch {
            return completionStream { _ in throw error }
        }
        let finalRequest = urlRequest
        return completionStream { emit in
            var finish: String?
            var blocked: String?
            var usage: Chunk.Usage?
            var version: String?
            let decoder = JSONDecoder()
            try await http.events(finalRequest, errors: Self.error) { sse in
                let data = Data(sse.data.utf8)
                if HTTPErrors.object(data)?["error"] != nil { throw Self.map(data, status: nil, retryAfter: nil) }
                guard let chunk = try? decoder.decode(Chunk.self, from: data) else { return true }
                version = chunk.modelVersion ?? version
                usage = chunk.usageMetadata ?? usage
                blocked = chunk.promptFeedback?.blockReason ?? blocked
                if let candidate = chunk.candidates?.first {
                    for part in candidate.content?.parts ?? [] where part.thought != true {
                        if let text = part.text, !text.isEmpty { emit(.text(text)) }
                    }
                    finish = candidate.finishReason ?? finish
                }
                return true
            }
            if let blocked { throw ProviderError.refused("The request was blocked (\(blocked))") }
            guard let finish else { throw ProviderError.incomplete("The connection closed before the answer finished") }
            if Self.refusalReasons.contains(finish) { throw ProviderError.refused("The answer was blocked (\(finish))") }
            let stop: CompletionResult.Stop = finish == "STOP" ? .complete : finish == "MAX_TOKENS" ? .maxTokens : .other
            emit(.finished(CompletionResult(stop: stop, model: version, inputTokens: usage?.promptTokenCount,
                                            outputTokens: usage?.candidatesTokenCount)))
        }
    }

    // MARK: - errors

    static let error: ErrorMapper = { status, body, response in
        map(body, status: status, retryAfter: HTTPErrors.retryAfter(response))
    }

    static func map(_ body: Data, status: Int?, retryAfter: Double?) -> ProviderError {
        let message = HTTPErrors.message(body)
        // an invalid key comes back as 400 INVALID_ARGUMENT
        if String(decoding: body, as: UTF8.self).contains("API_KEY_INVALID") { return .unauthorized(message) }
        switch HTTPErrors.code(body) {
        case "UNAUTHENTICATED": return .unauthorized(message)
        case "PERMISSION_DENIED": return .forbidden(message)
        case "RESOURCE_EXHAUSTED":
            // a daily quota does not come back by retrying; a per-minute one says when to retry
            let text = String(decoding: body, as: UTF8.self)
            if text.contains("PerDay") { return .usageLimit(message) }
            return .rateLimited(retryAfter: retryAfter ?? retryDelay(body), message)
        case "UNAVAILABLE", "INTERNAL", "DEADLINE_EXCEEDED": return .unavailable(message)
        case "INVALID_ARGUMENT", "FAILED_PRECONDITION", "NOT_FOUND", "OUT_OF_RANGE": return .invalidRequest(message)
        default: return status.map { HTTPErrors.byStatus($0, message, retryAfter: retryAfter) } ?? .unavailable(message)
        }
    }

    /// Seconds from a `google.rpc.RetryInfo` detail (`"retryDelay": "37s"`).
    static func retryDelay(_ body: Data) -> Double? {
        let details = (HTTPErrors.object(body)?["error"] as? [String: Any])?["details"] as? [[String: Any]] ?? []
        for detail in details where (detail["@type"] as? String)?.hasSuffix("google.rpc.RetryInfo") == true {
            if let delay = detail["retryDelay"] as? String, delay.hasSuffix("s") { return Double(delay.dropLast()) }
        }
        return nil
    }
}
