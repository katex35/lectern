import Foundation

/// Any server with the OpenAI Chat Completions format: CLIProxyAPI, Ollama, LM Studio, OpenRouter, vLLM.
/// `baseURL` is the part before `/chat/completions`, for example `http://127.0.0.1:8317/v1`.
public struct OpenAICompatibleProvider: LanguageModelProvider {
    public let kind = ProviderKind.openAICompatible
    let baseURL: URL
    let apiKey: String?
    let http: HTTPClient

    public init(baseURL: URL, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.http = HTTPClient(session: session)
    }

    func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    struct ModelList: Decodable {
        struct Model: Decodable {
            var id: String
        }

        var data: [Model]
    }

    public func models() async throws -> [ModelInfo] {
        try await http.json(ModelList.self, request("models"), errors: Self.error).data
            .map(\.id)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ModelInfo(id: $0) }
    }

    struct Body: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        var model: String
        var messages: [Message]
        var stream = true
        var max_tokens: Int?
    }

    struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                var content: String?
            }

            var delta: Delta?
            var finish_reason: String?
        }

        struct Usage: Decodable {
            var prompt_tokens: Int?
            var completion_tokens: Int?
        }

        var model: String?
        var choices: [Choice]?
        var usage: Usage?
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        let http = self.http
        var urlRequest = self.request("chat/completions")
        let messages = (request.system.isEmpty ? [] : [Body.Message(role: "system", content: request.system)])
            + request.messages.map { Body.Message(role: $0.role.rawValue, content: $0.text) }
        do {
            try urlRequest.setJSON(Body(model: request.model, messages: messages, max_tokens: request.maxOutputTokens))
        } catch {
            return completionStream { _ in throw error }
        }
        let finalRequest = urlRequest
        return completionStream { emit in
            var model: String?
            var finish: String?
            var usage: Chunk.Usage?
            var done = false
            let decoder = JSONDecoder()
            try await http.events(finalRequest, errors: Self.error) { sse in
                if sse.data == "[DONE]" {
                    done = true
                    return false
                }
                let data = Data(sse.data.utf8)
                if HTTPErrors.object(data)?["error"] != nil {
                    throw Self.map(code: HTTPErrors.code(data), status: nil, message: HTTPErrors.message(data))
                }
                guard let chunk = try? decoder.decode(Chunk.self, from: data) else { return true }
                model = chunk.model ?? model
                usage = chunk.usage ?? usage
                for choice in chunk.choices ?? [] {
                    if let text = choice.delta?.content, !text.isEmpty { emit(.text(text)) }
                    finish = choice.finish_reason ?? finish
                }
                return true
            }
            // some servers end with the finish reason and no [DONE]
            guard done || finish != nil else {
                throw ProviderError.incomplete("The connection closed before the answer finished")
            }
            let stop: CompletionResult.Stop
            switch finish {
            case "stop", nil: stop = .complete
            case "length": stop = .maxTokens
            case "content_filter": throw ProviderError.refused(nil)
            default: stop = .other
            }
            emit(.finished(CompletionResult(stop: stop, model: model, inputTokens: usage?.prompt_tokens,
                                            outputTokens: usage?.completion_tokens)))
        }
    }

    static let error: ErrorMapper = { status, body, response in
        HTTPErrors.byStatus(status, HTTPErrors.message(body), retryAfter: HTTPErrors.retryAfter(response))
    }

    static func map(code: String?, status: Int?, message: String) -> ProviderError {
        switch code {
        case "insufficient_quota": return .usageLimit(message)
        case "rate_limit_exceeded", "rate_limit_error": return .rateLimited(retryAfter: nil, message)
        case "invalid_api_key", "authentication_error": return .unauthorized(message)
        default: return .unavailable(message)
        }
    }
}
