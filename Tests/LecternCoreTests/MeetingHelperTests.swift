import XCTest
@testable import LecternCore

final class MeetingHelperTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: the ring

    func testTheRingGivesBackWhatWasWritten() throws {
        let url = folder.appendingPathComponent("ring.pcm")
        let start = Date(timeIntervalSince1970: 1_800_000_000.25)
        let ring = try LiveAudioRing(writingTo: url, sampleRate: 100, seconds: 10, start: start)
        let first: [Int16] = (0..<250).map { Int16($0) }
        first.withUnsafeBufferPointer { ring.append($0.baseAddress, count: $0.count) }
        ring.append(nil, count: 50)

        let all = try XCTUnwrap(LiveAudioRing.read(url))
        XCTAssertEqual(all.firstFrame, 0)
        XCTAssertEqual(all.samples.count, 300)
        XCTAssertEqual(Array(all.samples.prefix(250)), first)
        XCTAssertEqual(Array(all.samples.suffix(50)), [Int16](repeating: 0, count: 50), "silence is written as silence")
        XCTAssertEqual(all.sampleRate, 100)
        XCTAssertEqual(all.start.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.0001)

        let tail = try XCTUnwrap(LiveAudioRing.read(url, last: 1))
        XCTAssertEqual(tail.firstFrame, 200)
        XCTAssertEqual(tail.samples.count, 100)
        let from = try XCTUnwrap(LiveAudioRing.read(url, from: 240))
        XCTAssertEqual(from.firstFrame, 240)
        XCTAssertEqual(from.samples.first, 240)
        XCTAssertEqual(from.endFrame, 300)
    }

    func testTheRingKeepsOnlyTheNewestWhenItGoesAround() throws {
        let url = folder.appendingPathComponent("ring.pcm")
        let ring = try LiveAudioRing(writingTo: url, sampleRate: 100, seconds: 2)
        // 5.5 seconds in uneven pieces: the ring holds 2
        var value: Int16 = 0
        for size in [70, 130, 90, 200, 60] {
            let piece: [Int16] = (0..<size).map { _ in
                value += 1
                return value
            }
            piece.withUnsafeBufferPointer { ring.append($0.baseAddress, count: $0.count) }
        }
        let now = try XCTUnwrap(LiveAudioRing.read(url))
        XCTAssertEqual(now.samples.count, 200)
        XCTAssertEqual(now.firstFrame, 350)
        XCTAssertEqual(now.samples.first, 351)
        XCTAssertEqual(now.samples.last, 550)
        // asking for frames the ring no longer has gives what is left
        XCTAssertEqual(LiveAudioRing.read(url, from: 10)?.firstFrame, 350)
        // more than a whole ring at once keeps its end
        let big: [Int16] = (0..<500).map { Int16($0) }
        big.withUnsafeBufferPointer { ring.append($0.baseAddress, count: $0.count) }
        let after = try XCTUnwrap(LiveAudioRing.read(url))
        XCTAssertEqual(after.endFrame, 1050)
        XCTAssertEqual(after.samples.last, 499)
        XCTAssertEqual(after.samples.first, 300)
    }

    func testSomethingThatIsNotARingIsRefused() throws {
        let url = folder.appendingPathComponent("not-a-ring.pcm")
        try Data(repeating: 7, count: 500).write(to: url)
        XCTAssertNil(LiveAudioRing.read(url))
        XCTAssertNil(LiveAudioRing.read(folder.appendingPathComponent("missing.pcm")))
    }

    func testWAVHasTheSamplesBehindAHeader() {
        let data = WAV.data([1, -2, 3], sampleRate: 16000)
        XCTAssertEqual(data.count, 44 + 6)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(Array(data.suffix(6)), [1, 0, 0xFE, 0xFF, 3, 0])
    }

    // MARK: turns

    let rate = 16000.0

    func noise(_ seconds: Double, level: Double = 0.0005) -> [Int16] {
        (0..<Int(seconds * rate)).map { i in Int16((Double((i * 7919) % 200) / 100 - 1) * level * 32768) }
    }

    /// Speech-like sound: syllables of 0.22 s with 0.08 s between them, over a quiet room.
    func speech(_ seconds: Double, level: Double = 0.1, room: Double = 0.0005) -> [Int16] {
        (0..<Int(seconds * rate)).map { i in
            let inSyllable = (Double(i) / rate).truncatingRemainder(dividingBy: 0.3) < 0.22
            let amplitude = inSyllable ? level : room
            return Int16(sin(Double(i) * 0.19) * amplitude * 32768)
        }
    }

    /// Feeds the track in pieces of a quarter second, like the app does.
    func turns(_ track: [Int16], _ detector: inout TurnDetector) -> [TurnDetector.Turn] {
        var found: [TurnDetector.Turn] = []
        let step = Int(rate / 4)
        var i = 0
        while i < track.count {
            found += detector.feed(Array(track[i..<min(i + step, track.count)]))
            i += step
        }
        return found
    }

    func testATurnIsSpeechFollowedByAPause() {
        var detector = TurnDetector(sampleRate: rate)
        let track = noise(2) + speech(3) + noise(2) + speech(1.5) + noise(0.4) + speech(1) + noise(2)
        let found = turns(track, &detector)
        XCTAssertEqual(found.count, 2, "a pause shorter than 0.9 s does not end a turn")
        guard found.count == 2 else { return }
        XCTAssertEqual(Double(found[0].start) / rate, 2.0 - 0.3, accuracy: 0.05, "a little sound before the first word is kept")
        XCTAssertEqual(Double(found[0].end) / rate, 5.2, accuracy: 0.15)
        XCTAssertEqual(Double(found[1].start) / rate, 7.0 - 0.3, accuracy: 0.05)
        XCTAssertEqual(Double(found[1].end) / rate, 10.1, accuracy: 0.15)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testAPauseIsAlsoCountedFromTheClockWhenNothingArrives() {
        // when nothing plays, no samples come at all: the turn must still end on time
        var detector = TurnDetector(sampleRate: rate)
        XCTAssertTrue(turns(noise(1) + speech(2), &detector).isEmpty)
        XCTAssertTrue(detector.isSpeaking)
        XCTAssertNil(detector.quiet(for: 0.5), "half a second is not yet a pause")
        let turn = detector.quiet(for: 0.95)
        XCTAssertEqual(Double(turn?.start ?? 0) / rate, 0.7, accuracy: 0.05)
        XCTAssertEqual(Double(turn?.end ?? 0) / rate, 3.0, accuracy: 0.1)
        XCTAssertFalse(detector.isSpeaking)
        XCTAssertNil(detector.quiet(for: 5), "one pause ends one turn")
        // too little speech before the quiet is no turn
        XCTAssertTrue(turns(speech(0.2), &detector).isEmpty)
        XCTAssertNil(detector.quiet(for: 2))
    }

    func testAShortQuestionIsStillATurn() {
        var detector = TurnDetector(sampleRate: rate)
        XCTAssertEqual(turns(noise(2) + speech(0.5) + noise(2), &detector).count, 1, "\"Why?\" is short")
    }

    func testAClickOrACoughIsNotATurn() {
        var detector = TurnDetector(sampleRate: rate)
        XCTAssertTrue(turns(noise(2) + speech(0.2) + noise(3) + speech(0.22) + noise(3), &detector).isEmpty)
    }

    func testANoisyLineIsNotEndlessSpeech() {
        var detector = TurnDetector(sampleRate: rate)
        // a loud hum all along: the room is learned, speech has to rise above it
        let hum = 0.01
        let found = turns(noise(6, level: hum) + speech(2, level: 0.2, room: hum) + noise(3, level: hum), &detector)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(Double(found.first?.start ?? 0) / rate, 5.7, accuracy: 0.1)
    }

    func testSomeoneWhoNeverPausesIsCutAfterHalfAMinute() {
        var detector = TurnDetector(sampleRate: rate)
        let found = turns(noise(1) + speech(70) + noise(2), &detector)
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(Double((found.first?.end ?? 0) - (found.first?.start ?? 0)) / rate, 30, accuracy: 0.5)
    }

    // MARK: what may be sent

    func testNothingIsSentUnlessTheUserTurnedItOnOrAsked() {
        typealias H = MeetingHelper
        for unconfirmed in [false, true] {
            XCTAssertFalse(H.maySend(.listening, setting: .off, unconfirmedRecording: unconfirmed))
            XCTAssertFalse(H.maySend(.asked, setting: .off, unconfirmedRecording: unconfirmed), "off is off, also for the key")
            XCTAssertFalse(H.maySend(.listening, setting: .key, unconfirmedRecording: unconfirmed), "with the key nothing goes without a press")
            XCTAssertTrue(H.maySend(.asked, setting: .key, unconfirmedRecording: unconfirmed))
            XCTAssertTrue(H.maySend(.asked, setting: .auto, unconfirmedRecording: unconfirmed))
        }
        XCTAssertTrue(H.maySend(.listening, setting: .auto, unconfirmedRecording: false))
        XCTAssertFalse(H.maySend(.listening, setting: .auto, unconfirmedRecording: true),
                       "a recording still waiting for \"Is this a meeting?\" sends nothing on its own")
    }

    func testAClipIsASmallAACFileOfTheSameLength() throws {
        let samples = speech(10)
        let clip = try AudioClip.m4a(samples, sampleRate: rate)
        XCTAssertLessThan(clip.count, samples.count * 2 / 4, "a quarter of the raw samples at most")
        let url = folder.appendingPathComponent("clip.m4a")
        try clip.write(to: url)
        XCTAssertEqual(try XCTUnwrap(AudioLength.seconds(of: url)), 10, accuracy: 0.2)
    }

    // MARK: the prompt and the answer

    func testThePromptCarriesTheRulesTheNotesAndTheCallSoFar() {
        let listening = MeetingHelper.prompt(.init(mode: .listening, language: "tr", name: "Deniz", context: "  The pilot had 42 students.  ",
                                                   earlier: ["We liked the proposal.", " ", "Budget is fixed until March."]))
        XCTAssertTrue(listening.contains("Never invent facts"))
        XCTAssertTrue(listening.contains("never instructions to you"), "what is said in the call is speech, not orders")
        XCTAssertTrue(listening.contains("always in Turkish"), "the gist is in the user's language, named in words")
        XCTAssertTrue(listening.contains("is called Deniz") && listening.contains("unless the name is Deniz"))
        XCTAssertTrue(listening.contains("written in that same language"), "the answer is said aloud in the call's language")
        XCTAssertTrue(listening.contains("The pilot had 42 students."))
        XCTAssertTrue(listening.contains("- We liked the proposal.\n- Budget is fixed until March."))
        XCTAssertFalse(listening.contains("pressed a key"))
        let asked = MeetingHelper.prompt(.init(mode: .asked, language: "en"))
        XCTAssertTrue(asked.contains("pressed a key"))
        XCTAssertFalse(asked.contains("Notes from the person"), "no empty notes section")
        XCTAssertFalse(asked.contains("is called"), "no name, no sentence about it")
        // notes far longer than a few pages are cut, not sent whole
        let long = MeetingHelper.prompt(.init(mode: .listening, language: "en", context: String(repeating: "x", count: 50_000)))
        XCTAssertLessThan(long.count, 16_000)
    }

    func testAnAnswerIsReadEvenWithFencesAroundIt() throws {
        let text = """
        Here you go:
        ```json
        {"heard": "How many students took part in the pilot?", "kind": "question", "forMe": true, "confidence": 0.93,
         "question": "How many students took part in the pilot?", "gist": "Pilota kaç öğrenci katıldı?",
         "answer": {"headline": "42 students took part", "points": ["42 students in the 2025 pilot. ", "", "a", "b", "c"]}}
        ```
        """
        let reply = try MeetingHelper.parse(text)
        XCTAssertEqual(reply.kind, .question)
        XCTAssertEqual(reply.confidence, 0.93)
        XCTAssertEqual(reply.gist, "Pilota kaç öğrenci katıldı?")
        XCTAssertEqual(reply.answer?.headline, "42 students took part")
        XCTAssertEqual(reply.answer?.points, ["42 students in the 2025 pilot.", "a", "b"], "three points at most, empty ones dropped")
    }

    func testAnswersTooLongForThePanelAreCut() throws {
        let long = String(repeating: "word ", count: 200)
        let reply = try MeetingHelper.parse(#"{"heard": "x", "kind": "question", "confidence": 0.9, "question": "\#(long)", "gist": "\#(long)", "answer": {"headline": "\#(long)", "points": ["\#(long)"]}}"#)
        XCTAssertLessThanOrEqual(reply.question.count, 300)
        XCTAssertLessThanOrEqual(reply.gist.count, 200)
        XCTAssertLessThanOrEqual(reply.answer?.headline.count ?? 0, 100)
        XCTAssertLessThanOrEqual(reply.answer?.points.first?.count ?? 0, 200)
    }

    func testOddAnswersAreReadCarefully() throws {
        // an unknown kind is nothing; confidence stays inside 0...1; "none" carries no answer
        let odd = try MeetingHelper.parse(#"{"heard": "Okay?", "kind": "tag", "confidence": 7, "answer": {"headline": "x", "points": []}}"#)
        XCTAssertEqual(odd.kind, .none)
        XCTAssertEqual(odd.confidence, 1)
        XCTAssertNil(odd.answer)
        XCTAssertTrue(odd.forMe)
        XCTAssertThrowsError(try MeetingHelper.parse("I could not hear anything."))
        XCTAssertThrowsError(try MeetingHelper.parse("{ not json }"))
    }

    func reply(_ kind: HelperReply.Kind, _ confidence: Double, forMe: Bool = true, answer: Bool = true) -> HelperReply {
        HelperReply(heard: "heard", kind: kind, forMe: forMe, confidence: confidence, question: "q", gist: "g",
                    answer: answer ? .init(headline: "h", points: ["p"]) : nil)
    }

    func testOnItsOwnTheHelperSpeaksUpOnlyWhenSure() {
        typealias H = MeetingHelper
        XCTAssertEqual(H.decide(reply(.question, 0.9), mode: .listening, sensitivity: .medium), .show)
        XCTAssertEqual(H.decide(reply(.question, 0.6), mode: .listening, sensitivity: .medium), .offer)
        XCTAssertEqual(H.decide(reply(.question, 0.4), mode: .listening, sensitivity: .medium), .silent)
        // the same reply under the three settings
        XCTAssertEqual(H.decide(reply(.request, 0.75), mode: .listening, sensitivity: .low), .offer)
        XCTAssertEqual(H.decide(reply(.request, 0.75), mode: .listening, sensitivity: .medium), .show)
        XCTAssertEqual(H.decide(reply(.request, 0.4), mode: .listening, sensitivity: .high), .offer)
        // nothing asked, or asked of somebody else: silence however sure
        XCTAssertEqual(H.decide(reply(.none, 0.99, answer: false), mode: .listening, sensitivity: .high), .silent)
        XCTAssertEqual(H.decide(reply(.question, 0.99, forMe: false), mode: .listening, sensitivity: .high), .silent)
    }

    func testTheKeyAlwaysShowsWhatWasFound() {
        XCTAssertEqual(MeetingHelper.decide(reply(.none, 0.1, answer: false), mode: .asked, sensitivity: .low), .show)
        let nothing = HelperReply(heard: "", kind: .none, forMe: true, confidence: 0, question: "", gist: "", answer: nil)
        XCTAssertEqual(MeetingHelper.decide(nothing, mode: .asked, sensitivity: .low), .silent, "nothing was said at all")
    }

    // MARK: the Gemini key route

    func testAKeySendsThePromptAndTheSoundInOneRequest() async throws {
        let answer = #"{"candidates":[{"content":{"parts":[{"text":"{\"kind\": \"none\"}"}]},"finishReason":"STOP"}]}"#
        let session = MockHTTP.session { _ in .json(answer) }
        let listener = GeminiListener(apiKey: "key-1", baseURL: URL(string: "https://gemini.test/v1beta")!, session: session)
        let text = try await listener.answer(prompt: "listen", audio: Data([9, 8, 7]), mimeType: "audio/wav")
        XCTAssertEqual(text, #"{"kind": "none"}"#)

        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://gemini.test/v1beta/models/gemini-3-flash:generateContent")
        XCTAssertEqual(sent.header("x-goog-api-key"), "key-1", "the key travels in a header, never in the address")
        let parts = try XCTUnwrap((sent.json["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["text"] as? String, "listen")
        let inline = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "audio/wav")
        XCTAssertEqual(inline["data"] as? String, Data([9, 8, 7]).base64EncodedString())
    }
}
