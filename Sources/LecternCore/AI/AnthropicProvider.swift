import Foundation

/// Claude through the Anthropic Messages API with the user's own API key.
public struct AnthropicProvider: LanguageModelProvider {
    public static let defaultModel = "claude-opus-5-5"
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Models that take `fallbacks: "default"`: when a safety check declines the request, the API
    /// reruns it on a fallback model within the same call.
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
    static let defaultMaxTokens = 64000

    public let kind = ProviderKind.anthropic
    let apiKey: String
    let baseURL: URL
    let http: HTTPClient

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = HTTPClient(session: session)
    }

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    // MARK: - models

    struct ModelPage: Decodable {
        struct Model: Decodable {
            var id: String
            var display_name: String?
            var max_input_tokens: Int?
            var max_tokens: Int?
            var capabilities: Capabilities?
        }

        struct Capabilities: Decodable {
            var effort: EffortSupport?
        }

        struct EffortSupport: Decodable {
            struct Level: Decodable {
                var supported: Bool
            }

            var supported: Bool?
            var low: Level?
            var medium: Level?
            var high: Level?
        }

        var data: [Model]
        var has_more: Bool?
        var last_id: String?
    }

    public func models() async throws -> [ModelInfo] {
        var models: [ModelInfo] = []
        var after: String?
        repeat {
            var components = URLComponents(url: baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            let page = try await http.json(ModelPage.self, request(components.url!), errors: Self.error)
            models += page.data.map { model in
                var levels: [Effort] = []
                if let effort = model.capabilities?.effort, effort.supported != false {
                    if effort.low?.supported == true { levels.append(.low) }
                    if effort.medium?.supported == true { levels.append(.medium) }
                    if effort.high?.supported == true { levels.append(.high) }
                }
                return ModelInfo(id: model.id, name: model.display_name, contextTokens: model.max_input_tokens,
                                 maxOutputTokens: model.max_tokens, effortLevels: levels)
            }
            after = page.has_more == true ? page.last_id : nil
        } while after != nil
        return models
    }

    // MARK: - messages

    struct Body: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        struct OutputConfig: Encodable {
            var effort: String
        }

        var model: String
        var max_tokens: Int
        var stream = true
        var system: String?
        var messages: [Message]
        var output_config: OutputConfig?
        var fallbacks: String?
    }

    func messagesRequest(_ request: CompletionRequest) throws -> URLRequest {
        let fallback = Self.fallbackModels.contains(request.model)
        let body = Body(
            model: request.model,
            max_tokens: request.maxOutputTokens ?? Self.defaultMaxTokens,
            system: request.system.isEmpty ? nil : request.system,
            messages: request.messages.map { Body.Message(role: $0.role.rawValue, content: $0.text) },
            output_config: request.effort.map { Body.OutputConfig(effort: $0.rawValue) },
            fallbacks: fallback ? "default" : nil)
        var urlRequest = self.request(baseURL.appendingPathComponent("v1/messages"))
        if fallback { urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        try urlRequest.setJSON(body)
        return urlRequest
    }

    struct StreamEvent: Decodable {
        struct Message: Decodable {
            var model: String?
            var usage: Usage?
        }

        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
        }

        struct Block: Decodable {
            struct Target: Decodable {
                var model: String?
            }

            var type: String
            var text: String?
            /// On a `fallback` block: the model that took over.
            var to: Target?
        }

        struct StopDetails: Decodable {
            var category: String?
            var explanation: String?
        }

        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stop_reason: String?
            var stop_details: StopDetails?
        }

        struct APIError: Decodable {
            var type: String?
            var message: String?
        }

        var type: String
        var message: Message?
        var content_block: Block?
        var delta: Delta?
        var usage: Usage?
        var stop_details: StopDetails?
        var error: APIError?
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        let http = self.http
        let urlRequest: URLRequest
        do {
            urlRequest = try messagesRequest(request)
        } catch {
            return completionStream { _ in throw error }
        }
        return completionStream { emit in
            var model: String?
            var inputTokens: Int?
            var outputTokens: Int?
            var stopReason: String?
            var stopDetails: StopDetails?
            var stopped = false
            let decoder = JSONDecoder()
            try await http.events(urlRequest, errors: Self.error) { sse in
                guard let event = try? decoder.decode(StreamEvent.self, from: Data(sse.data.utf8)) else { return true }
                switch event.type {
                case "message_start":
                    model = event.message?.model ?? model
                    inputTokens = event.message?.usage?.input_tokens ?? inputTokens
                case "content_block_start":
                    // after a mid-answer fallback the partial text stays and the fallback model continues it
                    if event.content_block?.type == "fallback", let to = event.content_block?.to?.model { model = to }
                    if event.content_block?.type == "text", let text = event.content_block?.text, !text.isEmpty {
                        emit(.text(text))
                    }
                case "content_block_delta":
                    if event.delta?.type == "text_delta", let text = event.delta?.text { emit(.text(text)) }
                case "message_delta":
                    stopReason = event.delta?.stop_reason ?? stopReason
                    stopDetails = event.delta?.stop_details ?? event.stop_details ?? stopDetails
                    inputTokens = event.usage?.input_tokens ?? inputTokens
                    outputTokens = event.usage?.output_tokens ?? outputTokens
                case "message_stop":
                    stopped = true
                    return false
                case "error":
                    throw Self.map(type: event.error?.type, status: nil, message: event.error?.message ?? "Stream error",
                                   retryAfter: nil)
                default:
                    break
                }
                return true
            }
            guard stopped else { throw ProviderError.incomplete("The connection closed before the answer finished") }
            let stop: CompletionResult.Stop
            switch stopReason {
            case "end_turn", "stop_sequence": stop = .complete
            case "max_tokens", "model_context_window_exceeded": stop = .maxTokens
            case "refusal": throw ProviderError.refused(stopDetails?.explanation)
            default: stop = .other
            }
            emit(.finished(CompletionResult(stop: stop, model: model, inputTokens: inputTokens, outputTokens: outputTokens)))
        }
    }

    typealias StopDetails = StreamEvent.StopDetails

    // MARK: - errors

    static let error: ErrorMapper = { status, body, response in
        let message = HTTPErrors.message(HTTPErrors.message(body), requestID: "request-id", in: response)
        return map(type: HTTPErrors.code(body), status: status, message: message, retryAfter: HTTPErrors.retryAfter(response))
    }

    static func map(type: String?, status: Int?, message: String, retryAfter: Double?) -> ProviderError {
        switch type {
        case "authentication_error": return .unauthorized(message)
        case "permission_error": return .forbidden(message)
        case "rate_limit_error": return .rateLimited(retryAfter: retryAfter, message)
        case "overloaded_error", "api_error", "timeout_error": return .unavailable(message)
        case "billing_error": return .usageLimit(message)
        case "invalid_request_error", "not_found_error", "request_too_large": return .invalidRequest(message)
        default: return status.map { HTTPErrors.byStatus($0, message, retryAfter: retryAfter) } ?? .unavailable(message)
        }
    }
}
