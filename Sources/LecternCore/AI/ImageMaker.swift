import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws one square picture from a prompt and returns its file data.
public protocol ImageMaker: Sendable {
    func image(prompt: String) async throws -> Data
}

/// GPT Image on a linked ChatGPT account, through the Codex backend's `image_generation` tool: the
/// request is a Responses call whose only tool is the image model, and the picture comes back in the
/// `image_generation_call` output item.
public struct CodexImageMaker: ImageMaker {
    public static let defaultModel = "gpt-image-2.5-flare"
    /// The text model that calls the tool.
    static let mainModel = "gpt-5.4-mini"

    let session: CodexSession
    let model: String
    let baseURL: URL
    let http: HTTPClient

    public init(session: CodexSession, model: String = CodexImageMaker.defaultModel,
                baseURL: URL = CodexAuth.backend, urlSession: URLSession = .shared) {
        self.session = session
        self.model = model
        self.baseURL = baseURL
        self.http = HTTPClient(session: urlSession)
    }

    struct Body: Encodable {
        struct Reasoning: Encodable {
            var effort = "medium"
            var summary = "auto"
        }

        struct ToolChoice: Encodable {
            var type = "image_generation"
        }

        struct Tool: Encodable {
            var type = "image_generation"
            var action = "generate"
            var model: String
            var size = "1024x1024"
            var quality = "medium"
            var output_format = "jpeg"
            var moderation = "auto"
            var output_compression = 85
        }

        struct Message: Encodable {
            struct Part: Encodable {
                var type = "input_text"
                var text: String
            }

            var type = "message"
            var role = "user"
            var content: [Part]
        }

        var instructions = ""
        var stream = true
        var reasoning = Reasoning()
        var parallel_tool_calls = true
        var include = ["reasoning.encrypted_content"]
        var model = CodexImageMaker.mainModel
        var store = false
        var tool_choice = ToolChoice()
        var tools: [Tool]
        var input: [Message]
    }

    struct Event: Decodable {
        struct Item: Decodable {
            var type: String?
            var result: String?
        }

        struct Response: Decodable {
            var output: [Item]?
            var error: OpenAIProvider.StreamEvent.APIError?
        }

        var type: String
        var item: Item?
        var output_index: Int?
        var response: Response?
        var code: String?
        var message: String?
        var error: OpenAIProvider.StreamEvent.APIError?
    }

    public func image(prompt: String) async throws -> Data {
        let body = Body(tools: [Body.Tool(model: model)], input: [Body.Message(content: [Body.Message.Part(text: prompt)])])
        do {
            return try await send(body, freshToken: false)
        } catch ProviderError.unauthorized {
            return try await send(body, freshToken: true)
        }
    }

    func send(_ body: Body, freshToken: Bool) async throws -> Data {
        let token = freshToken ? try await session.refresh().accessToken : try await session.accessToken()
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        try request.setJSON(body)
        CodexAuth.apply(to: &request, token: token, accountID: await session.accountID())
        request.timeoutInterval = 300

        var byIndex: [Int: String] = [:]
        var unindexed: [String] = []
        var finished: [String]?
        let decoder = JSONDecoder()
        try await http.events(request, errors: OpenAIProvider.error) { sse in
            guard let event = try? decoder.decode(Event.self, from: Data(sse.data.utf8)) else { return true }
            switch event.type {
            case "response.output_item.done":
                guard let item = event.item, item.type == "image_generation_call", let result = item.result, !result.isEmpty else { break }
                if let index = event.output_index { byIndex[index] = result } else { unindexed.append(result) }
            case "response.completed":
                let output = (event.response?.output ?? []).filter { $0.type == "image_generation_call" }.compactMap(\.result)
                    .filter { !$0.isEmpty }
                finished = output.isEmpty ? byIndex.sorted { $0.key < $1.key }.map(\.value) + unindexed : output
                return false
            case "response.failed":
                let error = event.response?.error
                throw OpenAIProvider.map(code: error?.code, param: error?.param, status: nil,
                                         message: error?.message ?? "The image failed", retryAfter: nil)
            case "error":
                throw OpenAIProvider.map(code: event.code ?? event.error?.code, param: event.error?.param, status: nil,
                                         message: event.message ?? event.error?.message ?? "Stream error", retryAfter: nil)
            default:
                break
            }
            return true
        }
        guard let finished else { throw ProviderError.incomplete("The connection closed before the image finished") }
        guard let encoded = finished.first, let data = Data(base64Encoded: encoded) else {
            throw ProviderError.invalidResponse("No image came back")
        }
        return data
    }
}

/// OpenAI's GPT Image models with an API key.
public struct OpenAIImageMaker: ImageMaker {
    public static let defaultModel = "gpt-image-2.5-flare"

    let apiKey: String
    let model: String
    let baseURL: URL
    let http: HTTPClient

    public init(apiKey: String, model: String = OpenAIImageMaker.defaultModel,
                baseURL: URL = URL(string: "https://api.openai.com/v1")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.http = HTTPClient(session: session)
    }

    struct Body: Encodable {
        var model: String
        var prompt: String
        var size = "1024x1024"
        var quality = "medium"
        var output_format = "jpeg"
        var output_compression = 85
        var moderation = "auto"
    }

    struct Reply: Decodable {
        struct Item: Decodable {
            var b64_json: String?
        }

        var data: [Item]
    }

    public func image(prompt: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("images/generations"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 180
        try request.setJSON(Body(model: model, prompt: prompt))
        let reply = try await http.json(Reply.self, request, errors: OpenAIProvider.error)
        guard let encoded = reply.data.first?.b64_json, let data = Data(base64Encoded: encoded) else {
            throw ProviderError.invalidResponse("No image came back")
        }
        return data
    }
}

/// Gemini's image models with a Google AI Studio key.
public struct GeminiImageMaker: ImageMaker {
    public static let defaultModel = "gemini-3.1-flash-image"

    let apiKey: String
    let model: String
    let baseURL: URL
    let http: HTTPClient

    public init(apiKey: String, model: String = GeminiImageMaker.defaultModel,
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
            var text: String
        }

        struct Config: Encodable {
            struct Image: Encodable {
                var aspectRatio = "1:1"
            }

            var responseModalities = ["IMAGE"]
            var imageConfig = Image()
        }

        var contents: [Content]
        var generationConfig = Config()
    }

    struct Reply: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                var parts: [Part]?
            }

            struct Part: Decodable {
                struct Blob: Decodable {
                    var data: String
                }

                var inlineData: Blob?
            }

            var content: Content?
            var finishReason: String?
        }

        var candidates: [Candidate]?
    }

    public func image(prompt: String) async throws -> Data {
        let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", ":"])) ?? model
        var request = URLRequest(url: URL(string: "\(baseURL.absoluteString)/models/\(name):generateContent")!)
        // in a header, never in the URL
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 180
        try request.setJSON(Body(contents: [Body.Content(parts: [Body.Part(text: prompt)])]))
        let reply = try await http.json(Reply.self, request, errors: GeminiProvider.error)
        let candidate = reply.candidates?.first
        if let reason = candidate?.finishReason, GeminiProvider.refusalReasons.contains(reason) {
            throw ProviderError.refused("The image was blocked (\(reason))")
        }
        guard let encoded = candidate?.content?.parts?.compactMap({ $0.inlineData?.data }).first,
              let data = Data(base64Encoded: encoded) else {
            throw ProviderError.invalidResponse("No image came back")
        }
        return data
    }
}

public enum CoverImage {
    /// Shrinks a picture to `pixels` on its long side and writes it as JPEG.
    public static func write(_ data: Data, to url: URL, pixels: Int = 640) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary) else {
            throw ProviderError.invalidResponse("The image could not be read")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProviderError.invalidResponse("The image could not be saved")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProviderError.invalidResponse("The image could not be saved") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
    }
}
