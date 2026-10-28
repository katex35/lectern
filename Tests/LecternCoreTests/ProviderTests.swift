import XCTest
@testable import LecternCore

final class SSEParserTests: XCTestCase {
    func testSplitsEventsAndJoinsDataLines() {
        var parser = SSEParser()
        var events: [ServerSentEvent] = []
        for line in [": keep-alive", "event: a", "data: one", "data:two", "", "", "data: {\"x\":1}", "id: 5", ""] {
            if let event = parser.feed(line) { events.append(event) }
        }
        XCTAssertEqual(events, [ServerSentEvent(event: "a", data: "one\ntwo"), ServerSentEvent(event: nil, data: "{\"x\":1}")])
        XCTAssertNil(parser.finish())
    }

    func testLastEventWithoutBlankLineStillCounts() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed("data: [DONE]"))
        XCTAssertEqual(parser.finish(), ServerSentEvent(event: nil, data: "[DONE]"))
    }
}

final class ProviderTests: XCTestCase {
    let request = CompletionRequest(model: "claude-opus-5-5", system: "Write notes.", messages: [ChatMessage(.user, "Transcript")])

    func collect(_ stream: AsyncThrowingStream<CompletionEvent, Error>) async throws -> (String, CompletionResult?) {
        var text = ""
        var result: CompletionResult?
        for try await event in stream {
            switch event {
            case .text(let piece): text += piece
            case .finished(let r): result = r
            }
        }
        return (text, result)
    }

    func expectError(_ expected: (ProviderError) -> Bool, _ body: () async throws -> Void,
                     file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch let error as ProviderError {
            XCTAssertTrue(expected(error), "\(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - Anthropic

    static let anthropicStream = sse([
        ("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":120}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("ping", #"{"type":"ping"}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Ders "}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"notları ğüşiöç"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ])

    func testAnthropicStreamsTextAndSkipsThinking() async throws {
        let session = MockHTTP.session { _ in .events(Self.anthropicStream) }
        let provider = AnthropicProvider(apiKey: "sk-test", session: session)
        let (text, result) = try await collect(provider.stream(request))
        XCTAssertEqual(text, "Ders notları ğüşiöç")
        XCTAssertEqual(result, CompletionResult(stop: .complete, model: "claude-opus-5-5", inputTokens: 120, outputTokens: 9))

        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.header("x-api-key"), "sk-test")
        XCTAssertEqual(sent.header("anthropic-version"), "2026-10-21")
        XCTAssertEqual(sent.header("anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = sent.json
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 64000)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "Write notes.")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["output_config"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first, ["role": "user", "content": "Transcript"])
    }

    func testAnthropicSendsEffortAndNoFallbackForOtherModels() async throws {
        let session = MockHTTP.session { _ in .events(Self.anthropicStream) }
        var haiku = request
        haiku.model = "claude-haiku-5-5"
        haiku.effort = .low
        haiku.maxOutputTokens = 8000
        _ = try await collect(AnthropicProvider(apiKey: "k", session: session).stream(haiku))
        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertNil(sent.header("anthropic-beta"))
        XCTAssertNil(sent.json["fallbacks"])
        XCTAssertEqual(sent.json["max_tokens"] as? Int, 8000)
        XCTAssertEqual((sent.json["output_config"] as? [String: String])?["effort"], "low")
    }

    func testAnthropicRefusalDiscardsTheAnswer() async {
        let stream = sse([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":null,"explanation":"declined"}}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let provider = AnthropicProvider(apiKey: "k", session: MockHTTP.session { _ in .events(stream) })
        await expectError({ $0 == .refused("declined") }) { _ = try await provider.complete(request) }
    }

    func testAnthropicFallbackBlockNamesTheModelThatFinished() async throws {
        let stream = sse([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Part one, "}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"part two."}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let provider = AnthropicProvider(apiKey: "k", session: MockHTTP.session { _ in .events(stream) })
        let (text, result) = try await provider.complete(request)
        XCTAssertEqual(text, "Part one, part two.")
        XCTAssertEqual(result.model, "claude-opus-4-8")
    }

    func testAnthropicErrors() async {
        let overloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        var provider = AnthropicProvider(apiKey: "k", session: MockHTTP.session { _ in
            .json(overloaded, status: 529, headers: ["request-id": "req_9"])
        })
        await expectError({ $0 == .unavailable("Overloaded (request req_9)") }) { _ = try await provider.complete(self.request) }

        provider = AnthropicProvider(apiKey: "bad", session: MockHTTP.session { _ in
            .json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401)
        })
        await expectError({ $0 == .unauthorized("invalid x-api-key") }) { _ = try await provider.models() }

        provider = AnthropicProvider(apiKey: "k", session: MockHTTP.session { _ in
            .json(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#, status: 429,
                  headers: ["retry-after": "12"])
        })
        await expectError({ $0 == .rateLimited(retryAfter: 12, "slow down") }) { _ = try await provider.complete(self.request) }

        // an error event in the middle of the stream
        let midStream = sse([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5"}}"#),
            ("error", overloaded),
        ])
        provider = AnthropicProvider(apiKey: "k", session: MockHTTP.session { _ in .events(midStream) })
        await expectError({ $0 == .unavailable("Overloaded") }) { _ = try await provider.complete(self.request) }
    }

    func testAnthropicStreamCutShortIsIncomplete() async {
        let cut = String(Self.anthropicStream.prefix(900))
        var provider = AnthropicProvider(apiKey: "k", session: MockHTTP.session { _ in .events(cut) })
        await expectError({ if case .incomplete = $0 { return true }; return false }) { _ = try await provider.complete(self.request) }

        provider = AnthropicProvider(apiKey: "k", session: MockHTTP.session { _ in .events(cut, drop: true) })
        await expectError({ if case .network = $0 { return true }; return false }) { _ = try await provider.complete(self.request) }
    }

    func testAnthropicModelsFollowPagesAndReadEffort() async throws {
        let session = MockHTTP.session { recorded in
            if recorded.request.url?.query?.contains("after_id=b") == true {
                return .json(#"{"data":[{"id":"c","display_name":"C"}],"has_more":false,"last_id":"c"}"#)
            }
            return .json(#"""
            {"data":[
              {"id":"a","display_name":"Claude A","max_input_tokens":1000000,"max_tokens":128000,
               "capabilities":{"effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},
                               "high":{"supported":true},"max":{"supported":true}}}},
              {"id":"b","display_name":"Claude B","capabilities":{"effort":{"supported":false}}}
            ],"has_more":true,"last_id":"b"}
            """#)
        }
        let models = try await AnthropicProvider(apiKey: "k", session: session).models()
        XCTAssertEqual(models.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(models[0], ModelInfo(id: "a", name: "Claude A", contextTokens: 1_000_000, maxOutputTokens: 128_000,
                                            effortLevels: [.low, .medium, .high]))
        XCTAssertEqual(models[1].effortLevels, [])
        XCTAssertEqual(MockHTTP.requests.count, 2)
        XCTAssertTrue(MockHTTP.requests[0].request.url?.query?.contains("limit=1000") == true)
    }

    // MARK: - OpenAI Responses

    static let responsesStream = sse([
        ("response.created", #"{"type":"response.created","response":{"id":"r1","model":"gpt-6","status":"in_progress"}}"#),
        ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"Merhaba "}"#),
        ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","delta":"thinking"}"#),
        ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"dünya"}"#),
        ("response.completed", #"{"type":"response.completed","response":{"model":"gpt-6","status":"completed","usage":{"input_tokens":30,"output_tokens":4}}}"#),
    ])

    func testOpenAIKeyStreamsResponses() async throws {
        let session = MockHTTP.session { _ in .events(Self.responsesStream) }
        var openAIRequest = request
        openAIRequest.model = "gpt-6"
        openAIRequest.maxOutputTokens = 5000
        openAIRequest.messages = [ChatMessage(.user, "a"), ChatMessage(.assistant, "b"), ChatMessage(.user, "c")]
        let (text, result) = try await OpenAIProvider(credential: .apiKey("sk-o"), session: session).complete(openAIRequest)
        XCTAssertEqual(text, "Merhaba dünya")
        XCTAssertEqual(result, CompletionResult(stop: .complete, model: "gpt-6", inputTokens: 30, outputTokens: 4))
        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(sent.header("Authorization"), "Bearer sk-o")
        XCTAssertEqual(sent.json["store"] as? Bool, false)
        XCTAssertEqual(sent.json["stream"] as? Bool, true)
        XCTAssertEqual(sent.json["instructions"] as? String, "Write notes.")
        XCTAssertEqual(sent.json["max_output_tokens"] as? Int, 5000)
        let input = try XCTUnwrap(sent.json["input"] as? [[String: String]])
        XCTAssertEqual(input.map { $0["role"] }, ["user", "assistant", "user"])
        XCTAssertEqual(input.first?["type"], "message")
    }

    func testOpenAIStreamWithoutCompletedIsIncomplete() async {
        let unfinished = sse([("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"half"}"#)])
        let provider = OpenAIProvider(credential: .apiKey("k"), session: MockHTTP.session { _ in .events(unfinished) })
        await expectError({ if case .incomplete = $0 { return true }; return false }) { _ = try await provider.complete(self.request) }
    }

    func testOpenAIErrorsByCode() async {
        let failed = sse([
            ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"x"}"#),
            ("response.failed", #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Limit reached"}}}"#),
        ])
        var provider = OpenAIProvider(credential: .apiKey("k"), session: MockHTTP.session { _ in .events(failed) })
        await expectError({ $0 == .usageLimit("Limit reached") }) { _ = try await provider.complete(self.request) }

        provider = OpenAIProvider(credential: .apiKey("k"), session: MockHTTP.session { _ in
            .json(#"{"error":{"message":"No quota","type":"insufficient_quota","code":"insufficient_quota"}}"#, status: 429,
                  headers: ["x-request-id": "abc"])
        })
        await expectError({ $0 == .usageLimit("No quota (request abc)") }) { _ = try await provider.complete(self.request) }

        provider = OpenAIProvider(credential: .apiKey("k"), session: MockHTTP.session { _ in
            .json(#"{"error":{"message":"Not supported","code":"subscription_sharing_unsupported_capability","param":"tools"}}"#,
                  status: 400)
        })
        await expectError({ $0 == .invalidRequest("Not supported (tools)") }) { _ = try await provider.complete(self.request) }

        provider = OpenAIProvider(credential: .apiKey("k"), session: MockHTTP.session { _ in
            .json(#"{"detail":"Direct routing unavailable"}"#, status: 503)
        })
        await expectError({ $0 == .unavailable("Direct routing unavailable") }) { _ = try await provider.complete(self.request) }
    }

    func testOpenAIKeyModelsKeepTextModelsNewestFirst() async throws {
        let session = MockHTTP.session { _ in
            .json(#"""
            {"object":"list","data":[
              {"id":"gpt-5","created":100},{"id":"whisper-1","created":300},{"id":"gpt-6","created":200},
              {"id":"gpt-6-realtime","created":250},{"id":"o4-mini","created":150},{"id":"text-embedding-3-large","created":90},
              {"id":"omni-moderation-latest","created":80}
            ]}
            """#)
        }
        let models = try await OpenAIProvider(credential: .apiKey("k"), session: session).models()
        XCTAssertEqual(models.map(\.id), ["gpt-6", "o4-mini", "gpt-5"])
    }

    // MARK: - OpenAI-compatible

    func testCompatibleEndpointStreamsChatCompletions() async throws {
        let stream = """
        data: {"id":"1","model":"local-model","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

        data: {"id":"1","choices":[{"index":0,"delta":{"content":"Selam"}}]}

        data: {"id":"1","choices":[{"index":0,"delta":{"content":" sınıf"},"finish_reason":"length"}]}

        data: [DONE]


        """
        let session = MockHTTP.session { _ in .events(stream) }
        let provider = OpenAICompatibleProvider(baseURL: URL(string: "http://127.0.0.1:8317/v1")!, session: session)
        let (text, result) = try await provider.complete(request)
        XCTAssertEqual(text, "Selam sınıf")
        XCTAssertEqual(result.stop, .maxTokens)
        XCTAssertEqual(result.model, "local-model")
        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "http://127.0.0.1:8317/v1/chat/completions")
        XCTAssertNil(sent.header("Authorization"))
        XCTAssertNil(sent.json["max_tokens"])
        let messages = try XCTUnwrap(sent.json["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "Write notes."], ["role": "user", "content": "Transcript"]])
    }

    func testCompatibleEndpointModelsAndKey() async throws {
        let session = MockHTTP.session { _ in .json(#"{"object":"list","data":[{"id":"model-10"},{"id":"model-9"}]}"#) }
        let provider = OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:11434/v1/")!, apiKey: "local", session: session)
        let models = try await provider.models()
        XCTAssertEqual(models.map(\.id), ["model-9", "model-10"])
        XCTAssertEqual(MockHTTP.requests.first?.header("Authorization"), "Bearer local")
        XCTAssertEqual(MockHTTP.requests.first?.request.url?.absoluteString, "http://localhost:11434/v1/models")
    }

    func testCompatibleEndpointErrorInsideTheStream() async {
        let stream = "data: {\"error\":{\"message\":\"model overloaded\",\"code\":503}}\n\n"
        let provider = OpenAICompatibleProvider(baseURL: URL(string: "http://127.0.0.1:1/v1")!,
                                                session: MockHTTP.session { _ in .events(stream) })
        await expectError({ $0 == .unavailable("model overloaded") }) { _ = try await provider.complete(self.request) }
    }

    // MARK: - Gemini

    func testGeminiStreamsAndSkipsThoughts() async throws {
        let stream = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"plan\",\"thought\":true}],\"role\":\"model\"}}]}\r\n\r\n"
            + "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Özet: \"}],\"role\":\"model\"}}],\"modelVersion\":\"gemini-3-pro\"}\r\n\r\n"
            + "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"tamam\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],"
            + "\"usageMetadata\":{\"promptTokenCount\":11,\"candidatesTokenCount\":3}}\r\n\r\n"
        let session = MockHTTP.session { _ in .events(stream) }
        var geminiRequest = request
        geminiRequest.model = "gemini-3-pro"
        geminiRequest.messages = [ChatMessage(.user, "q"), ChatMessage(.assistant, "a"), ChatMessage(.user, "q2")]
        let (text, result) = try await GeminiProvider(apiKey: "g-key", session: session).complete(geminiRequest)
        XCTAssertEqual(text, "Özet: tamam")
        XCTAssertEqual(result, CompletionResult(stop: .complete, model: "gemini-3-pro", inputTokens: 11, outputTokens: 3))
        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro:streamGenerateContent?alt=sse")
        XCTAssertEqual(sent.header("x-goog-api-key"), "g-key")
        XCTAssertFalse(sent.request.url!.absoluteString.contains("g-key"))
        let contents = try XCTUnwrap(sent.json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model", "user"])
        XCTAssertNotNil(sent.json["systemInstruction"])
        XCTAssertNil(sent.json["generationConfig"])
    }

    func testGeminiSafetyStopAndInvalidKey() async {
        let blocked = "data: {\"candidates\":[{\"finishReason\":\"SAFETY\"}]}\n\n"
        var provider = GeminiProvider(apiKey: "k", session: MockHTTP.session { _ in .events(blocked) })
        await expectError({ if case .refused = $0 { return true }; return false }) { _ = try await provider.complete(self.request) }

        let invalid = #"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#
        provider = GeminiProvider(apiKey: "bad", session: MockHTTP.session { _ in .json(invalid, status: 400) })
        await expectError({ $0 == .unauthorized("API key not valid.") }) { _ = try await provider.models() }

        let quota = #"[{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}]"#
        provider = GeminiProvider(apiKey: "k", session: MockHTTP.session { _ in .json(quota, status: 429) })
        await expectError({ $0 == .rateLimited(retryAfter: nil, "Quota exceeded") }) { _ = try await provider.complete(self.request) }
    }

    func testGeminiModelsKeepTextGenerators() async throws {
        let session = MockHTTP.session { _ in
            .json(#"""
            {"models":[
              {"name":"models/gemini-3-pro","displayName":"Gemini 3 Pro","inputTokenLimit":1048576,"outputTokenLimit":65536,
               "supportedGenerationMethods":["generateContent","countTokens"]},
              {"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]},
              {"name":"models/gemini-3-flash-preview-tts","supportedGenerationMethods":["generateContent"]},
              {"name":"models/imagen-4","supportedGenerationMethods":["predict"]}
            ]}
            """#)
        }
        let models = try await GeminiProvider(apiKey: "k", session: session).models()
        XCTAssertEqual(models, [ModelInfo(id: "gemini-3-pro", name: "Gemini 3 Pro", contextTokens: 1_048_576,
                                          maxOutputTokens: 65536)])
    }

    // MARK: - credentials

    func testCredentialsKeepKeysAndAccount() throws {
        let credentials = Credentials(store: MemorySecretStore())
        XCTAssertNil(try credentials.apiKey(for: .anthropic))
        try credentials.setAPIKey("  sk-ant  \n", for: .anthropic)
        XCTAssertEqual(try credentials.apiKey(for: .anthropic), "sk-ant")
        try credentials.setAPIKey("", for: .anthropic)
        XCTAssertNil(try credentials.apiKey(for: .anthropic))

        let host = try credentials.hostID()
        XCTAssertEqual(try credentials.hostID(), host)

        let account = ChatGPTAccount(clientID: "oaiapp_1", hostID: host, subject: "user-1", email: "a@b.c",
                                     tokens: ChatGPTTokens(idToken: "i", accessToken: "a", refreshToken: "r",
                                                           expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                                                           scopes: ["openid", ChatGPTAuth.planScope]))
        try credentials.setChatGPTAccount(account)
        XCTAssertEqual(try credentials.chatGPTAccount(), account)
        XCTAssertTrue(account.canUsePlan)
    }
}
