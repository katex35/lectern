import CryptoKit
import Foundation

/// Speech to text with a Gemini model through Cloud Code, on a linked Google account. The request is
/// the Gemini API's, wrapped the way the Antigravity editor sends it (`model`, `project`, `request`),
/// and the answer comes back under `response`.
public struct AntigravityTranscriber: Transcribing {
    public static let defaultModel = "gemini-3-flash"
    static let inlineLimit = GeminiTranscriber.inlineLimit

    let session: AntigravitySession
    let model: String
    let baseURL: URL
    let http: HTTPClient
    let version: AntigravityVersion

    public init(session: AntigravitySession, model: String = AntigravityTranscriber.defaultModel,
                baseURL: URL = AntigravityAuth.Endpoints.google.api, urlSession: URLSession = .shared,
                version: AntigravityVersion = .shared) {
        self.session = session
        self.model = model
        self.baseURL = baseURL
        self.http = HTTPClient(session: urlSession)
        self.version = version
    }

    struct Body: Encodable {
        struct Request: Encodable {
            var contents: [Content]
            var sessionId: String
        }

        struct Content: Encodable {
            var role = "user"
            var parts: [Part]
        }

        struct Part: Encodable {
            var text: String?
            var inlineData: GeminiTranscriber.Body.Blob?
        }

        var model: String
        var userAgent = "antigravity"
        var requestType = "agent"
        var project: String
        var requestId: String
        var request: Request
    }

    struct Reply: Decodable {
        var response: GeminiTranscriber.Response?
    }

    /// What the model is told; the languages and terms come from the course.
    static func prompt(languages: [String], vocabulary: [String]) -> String {
        var lines = [
            "Transcribe this recording word for word, in the language that is spoken. You are a transcriber, not a summarizer.",
            "Write only what is said: no summary, no headings, no bullet points, no timestamps, no descriptions of who is speaking or what is going on.",
            "The first line of your answer is the first sentence heard in the recording.",
            "Start a new line when the speaker changes. Write [unclear] where the words cannot be made out; never guess.",
            "Write formulas and terms the way they are said. Keep mixed-language speech as it is spoken.",
        ]
        if !languages.isEmpty { lines.append("Languages spoken: \(languages.joined(separator: ", ")).") }
        let terms = vocabulary.filter { !$0.isEmpty }.prefix(100)
        if !terms.isEmpty { lines.append("Names and terms to listen for: \(terms.joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }

    public func transcribe(_ audio: URL, languages: [String], vocabulary: [String]) async throws -> String {
        let data = try Data(contentsOf: audio)
        guard data.count <= Self.inlineLimit else { throw ProviderError.invalidRequest("The audio piece is too large") }
        let prompt = Self.prompt(languages: languages, vocabulary: vocabulary)
        let request = Body.Request(
            contents: [Body.Content(parts: [Body.Part(text: prompt),
                                            Body.Part(inlineData: GeminiTranscriber.Body.Blob(mimeType: "audio/mp4", data: data.base64EncodedString()))])],
            sessionId: Self.sessionID(for: prompt))
        do {
            return try await send(request, freshToken: false)
        } catch ProviderError.unauthorized {
            // a token Cloud Code rejects before it expires: one more try after a renewal
            return try await send(request, freshToken: true)
        }
    }

    func send(_ request: Body.Request, freshToken: Bool) async throws -> String {
        if freshToken { try await session.refresh() }
        let (token, project) = try await session.credentials()
        let body = Body(model: model, project: project, requestId: "agent-\(UUID().uuidString.lowercased())", request: request)
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("\(AntigravityAuth.apiVersion):generateContent"))
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(await version.userAgent(), forHTTPHeaderField: "User-Agent")
        urlRequest.timeoutInterval = 300
        try urlRequest.setJSON(body)

        let reply = try await http.json(Reply.self, urlRequest, errors: AntigravityAuth.apiError)
        guard let response = reply.response else { throw ProviderError.invalidResponse("No transcript came back") }
        if let blocked = response.promptFeedback?.blockReason { throw ProviderError.refused("The audio was blocked (\(blocked))") }
        guard let candidate = response.candidates?.first else { throw ProviderError.invalidResponse("No transcript came back") }
        if let reason = candidate.finishReason, GeminiProvider.refusalReasons.contains(reason) {
            throw ProviderError.refused("The transcript was blocked (\(reason))")
        }
        let text = (candidate.content?.parts ?? []).compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // a piece with nothing said in it comes back finished and empty; anything that did not finish
        // (cut at the output limit, no reason given) is tried again rather than kept short
        guard candidate.finishReason == "STOP" else {
            throw ProviderError.incomplete("The transcript did not finish (\(candidate.finishReason ?? "no reason"))")
        }
        return text
    }

    /// A session id that stays the same for the same prompt: the first eight bytes of its SHA-256,
    /// as a positive number with a leading minus, the way Antigravity numbers sessions.
    static func sessionID(for text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        let value = hash.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } & 0x7FFF_FFFF_FFFF_FFFF
        return "-\(value)"
    }
}
