import Foundation

/// The services Lectern can write notes with. Each one is linked with the user's own key or
/// account; Lectern has no server of its own and sends nothing anywhere else.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// Claude with an Anthropic API key.
    case anthropic
    /// "Sign in with ChatGPT": answers count against the user's ChatGPT plan.
    case chatGPT
    /// An OpenAI API key.
    case openAI
    /// A Google AI Studio API key.
    case gemini
    /// Any server that speaks the OpenAI Chat Completions format: Ollama, LM Studio, OpenRouter, vLLM.
    case openAICompatible
}

public enum Effort: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

public struct ModelInfo: Codable, Hashable, Identifiable, Sendable {
    /// The value sent as `model`.
    public var id: String
    public var name: String
    public var contextTokens: Int?
    public var maxOutputTokens: Int?
    /// Reasoning effort levels the model accepts; empty when unsupported or unknown.
    public var effortLevels: [Effort]

    public init(id: String, name: String? = nil, contextTokens: Int? = nil, maxOutputTokens: Int? = nil,
                effortLevels: [Effort] = []) {
        self.id = id
        self.name = name ?? id
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.effortLevels = effortLevels
    }
}

public struct ChatMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant
    }

    public var role: Role
    public var text: String

    public init(_ role: Role, _ text: String) {
        self.role = role
        self.text = text
    }
}

public struct CompletionRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [ChatMessage]
    /// Upper bound for the answer. Providers that take no limit ignore it; Anthropic requires one
    /// and uses 64000 when it is nil.
    public var maxOutputTokens: Int?
    /// Sent only by providers that support it; set it only when the model lists the level.
    public var effort: Effort?

    public init(model: String, system: String, messages: [ChatMessage], maxOutputTokens: Int? = nil,
                effort: Effort? = nil) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.effort = effort
    }
}

public struct CompletionResult: Sendable, Equatable {
    public enum Stop: String, Sendable {
        case complete
        /// The answer hit the output limit and is cut off.
        case maxTokens
        case other
    }

    public var stop: Stop
    /// The model that wrote the answer as the server reports it; it can differ from the requested one.
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(stop: Stop, model: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.stop = stop
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum CompletionEvent: Sendable, Equatable {
    case text(String)
    /// The last event of a successful answer. Text that came before it is only valid once this arrives.
    case finished(CompletionResult)
}

public enum ProviderError: Error, Equatable, LocalizedError {
    /// No key or sign-in for this provider.
    case notConnected
    /// The key was rejected or the sign-in ended: the user has to enter the key or sign in again.
    case unauthorized(String)
    /// This account may not do this (plan, region, permission). Retrying does not help.
    case forbidden(String)
    /// Too many requests; retry after `retryAfter` seconds when the server says.
    case rateLimited(retryAfter: Double?, String)
    /// The plan's or account's usage limit is reached. Never retry or switch billing on the user's behalf.
    case usageLimit(String)
    /// The service is overloaded or down; retry later.
    case unavailable(String)
    /// The request was rejected (unsupported model or field, input too long).
    case invalidRequest(String)
    /// The model declined to answer. Any text received before must be discarded.
    case refused(String?)
    /// The answer stopped before it was complete. Discard the partial text.
    case incomplete(String)
    /// The server answered with something that could not be read.
    case invalidResponse(String)
    case network(String)

    /// Worth another try later, unchanged.
    public var isTemporary: Bool {
        switch self {
        case .rateLimited, .unavailable, .incomplete, .network: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .refused(let message): return message ?? "The model declined to answer"
        case .rateLimited(_, let message): return message
        case .unauthorized(let message), .forbidden(let message), .usageLimit(let message), .unavailable(let message),
             .invalidRequest(let message), .incomplete(let message), .invalidResponse(let message), .network(let message):
            return message
        }
    }
}

public protocol LanguageModelProvider: Sendable {
    var kind: ProviderKind { get }
    /// The models this key or account can use, in the order to show them.
    func models() async throws -> [ModelInfo]
    /// Streams one answer. The text is valid only once `.finished` arrives; when the stream throws,
    /// discard what came before.
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error>
}

extension LanguageModelProvider {
    /// Runs a request to the end and returns the whole answer.
    public func complete(_ request: CompletionRequest,
                         onText: (@Sendable (String) -> Void)? = nil) async throws -> (text: String, result: CompletionResult) {
        var text = ""
        for try await event in stream(request) {
            switch event {
            case .text(let piece):
                text += piece
                onText?(piece)
            case .finished(let result):
                return (text, result)
            }
        }
        throw ProviderError.incomplete("The answer ended without a result")
    }
}

/// Runs `body` as the producer of a completion stream; cancelling the consumer cancels the request.
func completionStream(
    _ body: @escaping @Sendable (_ emit: @escaping @Sendable (CompletionEvent) -> Void) async throws -> Void
) -> AsyncThrowingStream<CompletionEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await body { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
