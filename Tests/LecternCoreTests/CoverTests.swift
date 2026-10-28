import XCTest
@testable import LecternCore

final class CoverPromptTests: XCTestCase {
    func testASafeIdeaIsKeptAndPutInTheStyle() {
        let subject = CoverPrompts.subject("\"A stylized lens made of overlapping translucent circles with floating pixels.\"\nextra")
        XCTAssertEqual(subject, "A stylized lens made of overlapping translucent circles with floating pixels")
        let prompt = CoverPrompts.image(subject: subject, color: "#3B82F6")
        XCTAssertTrue(prompt.hasPrefix("A stylized lens"))
        XCTAssertTrue(prompt.contains("Limited palette: #3B82F6 and lighter tints of it"))
        XCTAssertTrue(prompt.contains("Strictly no people"))
    }

    func testIdeasWithPeopleOrSymbolsFallBack() {
        let fallback = CoverPrompts.subject(nil)
        XCTAssertEqual(CoverPrompts.subject("A teacher pointing at a board"), fallback)
        XCTAssertEqual(CoverPrompts.subject("Two hands holding a glowing sphere"), fallback)
        XCTAssertEqual(CoverPrompts.subject("A national flag over hills"), fallback)
        XCTAssertEqual(CoverPrompts.subject(""), fallback)
        // plurals without an s
        XCTAssertEqual(CoverPrompts.subject("Two children stacking blocks"), fallback)
        XCTAssertEqual(CoverPrompts.subject("Floating bodies of light"), fallback)
        XCTAssertEqual(CoverPrompts.subject("Crossed knives on a table"), fallback)
        // short words count only whole: "manifold" and "surface" do not trip "man" and "face"
        XCTAssertNotEqual(CoverPrompts.subject("A smooth manifold surface with gentle curves"), fallback)
    }

    func testTheSubjectRequestNamesTheTopic() {
        let request = CoverPrompts.subjectRequest(model: "m", topic: "Zincir kuralı", course: "Computer Vision")
        XCTAssertEqual(request.messages.first?.text, "Topic: Zincir kuralı\nCourse: Computer Vision")
        XCTAssertEqual(request.maxOutputTokens, 200)
        XCTAssertTrue(request.system.contains("no people"))
    }
}

final class ImageMakerTests: XCTestCase {
    /// A 2x2 JPEG, enough for the decoder.
    static let tinyJPEG = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAACAAIBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==")!

    func testOpenAIImagesReturnBase64() async throws {
        let encoded = Self.tinyJPEG.base64EncodedString()
        let maker = OpenAIImageMaker(apiKey: "sk-x", session: MockHTTP.session { _ in .json(#"{"data":[{"b64_json":"\#(encoded)"}]}"#) })
        let data = try await maker.image(prompt: "a lens")
        XCTAssertEqual(data, Self.tinyJPEG)
        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.openai.com/v1/images/generations")
        XCTAssertEqual(sent.header("Authorization"), "Bearer sk-x")
        XCTAssertEqual(sent.json["model"] as? String, "gpt-image-2.5-flare")
        XCTAssertEqual(sent.json["size"] as? String, "1024x1024")
        XCTAssertEqual(sent.json["output_format"] as? String, "jpeg")
    }

    func testGeminiImagesComeAsInlineData() async throws {
        let encoded = Self.tinyJPEG.base64EncodedString()
        let reply = #"{"candidates":[{"content":{"parts":[{"text":"here"},{"inlineData":{"mimeType":"image/jpeg","data":"\#(encoded)"}}]},"finishReason":"STOP"}]}"#
        let maker = GeminiImageMaker(apiKey: "g-key", session: MockHTTP.session { _ in .json(reply) })
        let data = try await maker.image(prompt: "a lens")
        XCTAssertEqual(data, Self.tinyJPEG)
        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image:generateContent")
        XCTAssertEqual(sent.header("x-goog-api-key"), "g-key")
        let config = try XCTUnwrap(sent.json["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseModalities"] as? [String], ["IMAGE"])

        let blocked = GeminiImageMaker(apiKey: "k", session: MockHTTP.session { _ in
            .json(#"{"candidates":[{"finishReason":"IMAGE_SAFETY"}]}"#)
        })
        do {
            _ = try await blocked.image(prompt: "x")
            XCTFail("expected a refusal")
        } catch let error as ProviderError {
            if case .refused = error {} else { XCTFail("got \(error)") }
        }
    }

    func testCoversAreWrittenAsSmallJPEGs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString)/c.jpg")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CoverImage.write(Self.tinyJPEG, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try CoverImage.write(Data([1, 2, 3]), to: url))
    }
}
