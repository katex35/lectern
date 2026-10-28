import Foundation

/// Speech to text with Gemini's transcription model and a Google AI Studio key. Pieces are sent inside
/// the request, so no copy of the recording is left in the account's file storage.
public struct GeminiTranscriber: Sendable {
    public static let defaultModel = "gemini-3.5-transcribe"
    /// Requests carrying more audio than this are refused; pieces of a few minutes stay far below it.
    static let inlineLimit = 14 * 1024 * 1024

    let apiKey: String
    let model: String
    let baseURL: URL
    let http: HTTPClient

    public init(apiKey: String, model: String = GeminiTranscriber.defaultModel,
                baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.http = HTTPClient(session: session)
    }

    struct Body: Encodable {
        struct Content: Encodable {
            var parts: [Part]
        }

        struct Part: Encodable {
            var inlineData: Blob
        }

        struct Blob: Encodable {
            var mimeType: String
            var data: String
        }

        struct Config: Encodable {
            var audioTranscriptionConfig: Transcription
        }

        struct Transcription: Encodable {
            var languageCodes: [String]?
            var customVocabulary: [String]?
        }

        var contents: [Content]
        var generationConfig: Config
    }

    struct Response: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                var parts: [Part]?
            }

            struct Part: Decodable {
                var text: String?
            }

            var content: Content?
            var finishReason: String?
        }

        struct Feedback: Decodable {
            var blockReason: String?
        }

        var candidates: [Candidate]?
        var promptFeedback: Feedback?
    }

    /// The words spoken in `audio`, an .m4a piece.
    /// - Parameters:
    ///   - languages: BCP 47 codes of the lecture; empty lets the model detect them, and mixed speech is kept.
    ///   - vocabulary: names and terms to listen for, such as the course title.
    public func transcribe(_ audio: URL, languages: [String], vocabulary: [String]) async throws -> String {
        let data = try Data(contentsOf: audio)
        guard data.count <= Self.inlineLimit else { throw ProviderError.invalidRequest("The audio piece is too large") }
        let terms = Array(vocabulary.filter { !$0.isEmpty }.prefix(100))
        let body = Body(
            contents: [Body.Content(parts: [Body.Part(inlineData: Body.Blob(mimeType: "audio/mp4", data: data.base64EncodedString()))])],
            generationConfig: Body.Config(audioTranscriptionConfig: Body.Transcription(
                languageCodes: languages.isEmpty ? nil : languages,
                customVocabulary: terms.isEmpty ? nil : terms)))
        let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", ":"])) ?? model
        var request = URLRequest(url: URL(string: "\(baseURL.absoluteString)/models/\(name):generateContent")!)
        // in a header, never in the URL
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 300
        try request.setJSON(body)

        let response = try await http.json(Response.self, request, errors: GeminiProvider.error)
        if let blocked = response.promptFeedback?.blockReason { throw ProviderError.refused("The audio was blocked (\(blocked))") }
        guard let candidate = response.candidates?.first else { throw ProviderError.invalidResponse("No transcript came back") }
        if let reason = candidate.finishReason, GeminiProvider.refusalReasons.contains(reason) {
            throw ProviderError.refused("The transcript was blocked (\(reason))")
        }
        let text = (candidate.content?.parts ?? []).compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        // a piece with nothing said in it comes back finished and empty; empty for any other reason is tried again
        if text.isEmpty, candidate.finishReason != "STOP" {
            throw ProviderError.incomplete("The transcript came back empty (\(candidate.finishReason ?? "no reason"))")
        }
        return text
    }
}
