import Foundation

/// OpenAI's Responses API, used with an API key, with a signed-in ChatGPT account, or with a ChatGPT
/// account linked through the Codex sign-in.
///
/// With a ChatGPT account every request is `store: false, stream: true`, carries the whole history
/// in `input`, and leaves out the fields that route does not accept (`max_output_tokens`,
/// `temperature` and others): https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
///
/// With the Codex sign-in the same requests go to ChatGPT's Codex backend, introduced as the Codex
/// CLI, with `instructions` always present; the models are the ones that backend lists for the CLI.
public struct OpenAIProvider: LanguageModelProvider {
    public enum Credential: Sendable {
        case apiKey(String)
        case chatGPT(ChatGPTSession)
        case codex(CodexSession)
    }

    public var kind: ProviderKind {
        switch credential {
        case .chatGPT, .codex: return .chatGPT
        case .apiKey: return .openAI
        }
    }

    let credential: Credential
    let baseURL: URL
    let http: HTTPClient

    /// `baseURL` defaults to OpenAI's API, or to the Codex backend for a Codex sign-in.
    public init(credential: Credential, baseURL: URL? = nil, session: URLSession = .shared) {
        self.credential = credential
        if let baseURL {
            self.baseURL = baseURL
        } else if case .codex = credential {
            self.baseURL = CodexAuth.backend
        } else {
            self.baseURL = URL(string: "https://api.openai.com/v1")!
        }
        self.http = HTTPClient(session: session)
    }

    var isChatGPT: Bool { kind == .chatGPT }

    var isCodex: Bool {
        if case .codex = credential { return true }
        return false
    }

    func authorized(_ url: URL, freshToken: Bool) async throws -> URLRequest {
        var request = URLRequest(url: url)
        let token: String
        switch credential {
        case .apiKey(let key):
            token = key
        case .chatGPT(let session):
            token = freshToken ? try await session.refresh(force: true).accessToken : try await session.accessToken()
        case .codex(let session):
            token = freshToken ? try await session.refresh().accessToken : try await session.accessToken()
            CodexAuth.apply(to: &request, token: token, accountID: await session.accountID())
            return request
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The models the Codex backend offers the CLI, in the order its picker lists them; the backend
    /// has no listing of its own.
    public static let codexModels = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol",
                                     "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]

    // MARK: - models

    struct ModelList: Decodable {
        struct APIModel: Decodable {
            var id: String
            var created: Double?
        }

        struct PlanModel: Decodable {
            var slug: String
            var display_name: String?
            var visibility: String?
        }

        var data: [APIModel]?
        var models: [PlanModel]?
    }

    public func models() async throws -> [ModelInfo] {
        if isCodex { return Self.codexModels.map { ModelInfo(id: $0) } }
        let list = try await retryingOnce { fresh in
            try await http.json(ModelList.self, try await authorized(baseURL.appendingPathComponent("models"), freshToken: fresh),
                                errors: Self.error)
        }
        if let plan = list.models {
            // the plan's own picker: keep the server's order, only models meant to be listed
            return plan.filter { $0.visibility == "list" }.map { ModelInfo(id: $0.slug, name: $0.display_name) }
        }
        return (list.data ?? [])
            .filter { Self.isTextModel($0.id) }
            .sorted { ($0.created ?? 0, $0.id) > ($1.created ?? 0, $1.id) }
            .map { ModelInfo(id: $0.id) }
    }

    /// An API key lists every model; keep the ones that write text.
    static func isTextModel(_ id: String) -> Bool {
        let family = id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-")
            || (id.first == "o" && id.dropFirst().first?.isNumber == true)
        let excluded = ["audio", "realtime", "tts", "transcribe", "image", "embedding", "moderation", "search", "instruct"]
        return family && !excluded.contains { id.contains($0) }
    }

    /// A ChatGPT access token can be rejected before it expires: one more try with a refreshed token.
    func retryingOnce<T>(_ body: (_ freshToken: Bool) async throws -> T) async throws -> T {
        do {
            return try await body(false)
        } catch ProviderError.unauthorized(let message) {
            guard isChatGPT else { throw ProviderError.unauthorized(message) }
            return try await body(true)
        }
    }

    // MARK: - responses

    struct Body: Encodable {
        struct Message: Encodable {
            var type = "message"
            var role: String
            var content: String
        }

        var model: String
        var instructions: String?
        var input: [Message]
        var stream = true
        var store = false
        var max_output_tokens: Int?
    }

    func body(_ request: CompletionRequest) -> Body {
        // the Codex backend wants `instructions` present, empty when there are none
        Body(model: request.model,
             instructions: request.system.isEmpty ? (isCodex ? "" : nil) : request.system,
             input: request.messages.map { Body.Message(role: $0.role.rawValue, content: $0.text) },
             max_output_tokens: isChatGPT && !isCodex ? nil : request.maxOutputTokens)
    }

    struct StreamEvent: Decodable {
        struct Response: Decodable {
            var model: String?
            var usage: Usage?
            var error: APIError?
            var incomplete_details: Incomplete?
        }

        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
        }

        struct APIError: Decodable {
            var code: String?
            var message: String?
            var param: String?
        }

        struct Incomplete: Decodable {
            var reason: String?
        }

        var type: String
        var delta: String?
        var response: Response?
        var code: String?
        var message: String?
        var param: String?
        var error: APIError?
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        let provider = self
        let body = self.body(request)
        return completionStream { emit in
            var emitted = false
            try await provider.retryingOnce { fresh in
                // a retry after text arrived would repeat it
                guard !(fresh && emitted) else { throw ProviderError.unauthorized("The ChatGPT sign-in was rejected") }
                var urlRequest = try await provider.authorized(provider.baseURL.appendingPathComponent("responses"), freshToken: fresh)
                urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                try urlRequest.setJSON(body)
                if provider.isCodex { urlRequest.timeoutInterval = 300 }
                try await provider.run(urlRequest) { event in
                    if case .text = event { emitted = true }
                    emit(event)
                }
            }
        }
    }

    func run(_ urlRequest: URLRequest, emit: (CompletionEvent) -> Void) async throws {
        var model: String?
        var result: CompletionResult?
        let decoder = JSONDecoder()
        try await http.events(urlRequest, errors: Self.error) { sse in
            guard let event = try? decoder.decode(StreamEvent.self, from: Data(sse.data.utf8)) else { return true }
            switch event.type {
            case "response.created", "response.in_progress":
                model = event.response?.model ?? model
            case "response.output_text.delta":
                if let text = event.delta { emit(.text(text)) }
            case "response.completed":
                result = CompletionResult(stop: .complete, model: event.response?.model ?? model,
                                          inputTokens: event.response?.usage?.input_tokens,
                                          outputTokens: event.response?.usage?.output_tokens)
                return false
            case "response.incomplete":
                // not a completed answer; only a cut at the output limit is kept, marked as such
                let reason = event.response?.incomplete_details?.reason
                guard reason == "max_output_tokens" else {
                    if reason == "content_filter" { throw ProviderError.refused(nil) }
                    throw ProviderError.incomplete("The answer stopped early (\(reason ?? "no reason given"))")
                }
                result = CompletionResult(stop: .maxTokens, model: event.response?.model ?? model,
                                          inputTokens: event.response?.usage?.input_tokens,
                                          outputTokens: event.response?.usage?.output_tokens)
                return false
            case "response.failed":
                let error = event.response?.error
                throw Self.map(code: error?.code, param: error?.param, status: nil,
                               message: error?.message ?? "The answer failed", retryAfter: nil)
            case "error":
                throw Self.map(code: event.code ?? event.error?.code, param: event.param ?? event.error?.param, status: nil,
                               message: event.message ?? event.error?.message ?? "Stream error", retryAfter: nil)
            default:
                break
            }
            return true
        }
        guard let result else { throw ProviderError.incomplete("The connection closed before the answer finished") }
        emit(.finished(result))
    }

    // MARK: - errors

    static let error: ErrorMapper = { status, body, response in
        var param: String?
        if let error = HTTPErrors.object(body)?["error"] as? [String: Any] { param = error["param"] as? String }
        let message = HTTPErrors.message(HTTPErrors.message(body), requestID: "x-request-id", in: response)
        return map(code: HTTPErrors.code(body), param: param, status: status, message: message,
                   retryAfter: HTTPErrors.retryAfter(response))
    }

    /// Codes from https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery
    /// and the API's own error codes.
    static func map(code: String?, param: String?, status: Int?, message: String, retryAfter: Double?) -> ProviderError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded", "insufficient_quota":
            return .usageLimit(message)
        case "subscription_sharing_user_not_eligible", "subscription_sharing_route_not_supported",
             "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return .forbidden(message)
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable", "server_error",
             "server_is_overloaded":
            return .unavailable(message)
        case "subscription_sharing_unsupported_capability", "model_not_found", "context_length_exceeded":
            return .invalidRequest(param.map { "\(message) (\($0))" } ?? message)
        case "subscription_sharing_invalid_user", "invalid_api_key":
            return .unauthorized(message)
        case "rate_limit_exceeded":
            return .rateLimited(retryAfter: retryAfter, message)
        default:
            return status.map { HTTPErrors.byStatus($0, message, retryAfter: retryAfter) } ?? .unavailable(message)
        }
    }
}
