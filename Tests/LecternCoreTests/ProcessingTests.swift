import AVFoundation
import XCTest
@testable import LecternCore

/// Writes a mono file of `seconds` of tone with silent stretches over the given ranges.
private func writeLecture(_ url: URL, seconds: Double, silences: [ClosedRange<Double>]) throws {
    let rate = 16000.0
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
    ])
    let frames = AVAudioFrameCount(rate * seconds)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for i in 0..<Int(frames) {
        let t = Double(i) / rate
        samples[i] = silences.contains { $0.contains(t) } ? 0 : Float(0.4 * sin(2 * Double.pi * 330 * t))
    }
    try file.write(from: buffer)
}

final class AudioChunkerTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCutsFallInTheQuietNearEachMark() throws {
        let url = folder.appendingPathComponent("lecture.m4a")
        try writeLecture(url, seconds: 20, silences: [5.6...6.0, 12.4...12.8])
        let points = AudioChunker.cutPoints(of: url, length: 6, search: 1.5)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0], 5.8, accuracy: 0.25)
        XCTAssertEqual(points[1], 12.6, accuracy: 0.25)
    }

    func testShortRecordingIsOnePiece() throws {
        let url = folder.appendingPathComponent("short.m4a")
        try writeLecture(url, seconds: 7, silences: [])
        XCTAssertEqual(AudioChunker.cutPoints(of: url, length: 6), [])
    }

    func testPiecesCoverTheWholeRecording() async throws {
        let url = folder.appendingPathComponent("lecture.m4a")
        try writeLecture(url, seconds: 20, silences: [5.6...6.0, 12.4...12.8])
        let chunks = try await AudioChunker.split(url, length: 6, into: folder.appendingPathComponent("pieces"))
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.duration }, 20, accuracy: 0.1)
        for chunk in chunks {
            let length = try await AVURLAsset(url: chunk.url).load(.duration).seconds
            XCTAssertEqual(length, chunk.duration, accuracy: 0.2)
        }
    }
}

final class GeminiTranscriberTests: XCTestCase {
    func testSendsTheAudioInlineWithTheLanguageAndTerms() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("piece-\(UUID().uuidString).m4a")
        try Data([1, 2, 3, 4]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let reply = #"{"candidates":[{"content":{"parts":[{"text":"Bugün geri yayılımı "},{"text":"göreceğiz."}],"role":"model"},"finishReason":"STOP"}]}"#
        let transcriber = GeminiTranscriber(apiKey: "g-key", session: MockHTTP.session { _ in .json(reply) })
        let text = try await transcriber.transcribe(audio, languages: ["tr"], vocabulary: ["Computer Vision", ""])
        XCTAssertEqual(text, "Bugün geri yayılımı göreceğiz.")

        let sent = try XCTUnwrap(MockHTTP.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe:generateContent")
        XCTAssertEqual(sent.header("x-goog-api-key"), "g-key")
        XCTAssertFalse(sent.request.url!.absoluteString.contains("g-key"))
        let part = try XCTUnwrap(((sent.json["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first)
        let inline = try XCTUnwrap(part["inlineData"] as? [String: Any])
        XCTAssertEqual(inline["mimeType"] as? String, "audio/mp4")
        XCTAssertEqual(inline["data"] as? String, Data([1, 2, 3, 4]).base64EncodedString())
        let config = try XCTUnwrap((sent.json["generationConfig"] as? [String: Any])?["audioTranscriptionConfig"] as? [String: Any])
        XCTAssertEqual(config["languageCodes"] as? [String], ["tr"])
        XCTAssertEqual(config["customVocabulary"] as? [String], ["Computer Vision"])
    }

    func testSilentPieceAndErrors() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("piece-\(UUID().uuidString).m4a")
        try Data([0]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        var transcriber = GeminiTranscriber(apiKey: "k", session: MockHTTP.session { _ in
            .json(#"{"candidates":[{"content":{"role":"model"},"finishReason":"STOP"}]}"#)
        })
        let empty = try await transcriber.transcribe(audio, languages: [], vocabulary: [])
        XCTAssertEqual(empty, "")
        let config = (MockHTTP.requests.first?.json["generationConfig"] as? [String: Any])?["audioTranscriptionConfig"] as? [String: Any]
        XCTAssertNil(config?["languageCodes"])

        transcriber = GeminiTranscriber(apiKey: "k", session: MockHTTP.session { _ in
            .json(#"{"error":{"code":429,"message":"Daily limit","status":"RESOURCE_EXHAUSTED","details":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel"}]}}"#, status: 429)
        })
        do {
            _ = try await transcriber.transcribe(audio, languages: [], vocabulary: [])
            XCTFail("expected a usage limit")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .usageLimit("Daily limit"))
        }
    }
}

/// Answers each transcription with the piece's name, counting calls; fails the first call when asked.
private final class FakeTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var failFirst: ProviderError?

    var called: [String] { lock.withLock { calls } }

    func transcribe(_ audio: URL, languages: [String], vocabulary: [String]) async throws -> String {
        let first = lock.withLock { () -> Bool in
            calls.append(audio.lastPathComponent)
            return calls.count == 1
        }
        if first, let failFirst { throw failFirst }
        return "words of \(audio.deletingPathExtension().lastPathComponent) in \(languages.joined())"
    }
}

/// Writes a fixed answer and keeps the requests.
private final class FakeWriter: LanguageModelProvider, @unchecked Sendable {
    let kind = ProviderKind.anthropic
    private let lock = NSLock()
    private var sent: [CompletionRequest] = []

    var requests: [CompletionRequest] { lock.withLock { sent } }

    func models() async throws -> [ModelInfo] { [] }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        lock.withLock { sent.append(request) }
        let answer = request.system.contains("practice questions") ? "# Sorular\n1. Ne?" : "# Geri yayılım\n## Giriş"
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(answer))
            continuation.yield(.finished(CompletionResult(stop: .complete)))
            continuation.finish()
        }
    }
}

final class SessionProcessorTests: XCTestCase {
    var root: URL!
    var library: Library!
    let course = Course(id: "GORU", name: "Computer Vision", language: "tr")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        library = Library(root: root)
        try library.save(course)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A lecture with two recordings of 14 s and 8 s and a note in the second one.
    func makeSession() throws -> Session {
        var session = try library.lectureSession(course: course, date: Date(timeIntervalSince1970: 1_800_000_000), week: 6)
        let folder = library.folder(of: session)
        try writeLecture(folder.appendingPathComponent("a.m4a"), seconds: 14, silences: [6.8...7.2])
        try writeLecture(folder.appendingPathComponent("b.m4a"), seconds: 8, silences: [])
        session.recordings = [
            RecordingInfo(file: "a.m4a", start: Date(timeIntervalSince1970: 1_800_000_000), duration: 14, inProgress: false),
            RecordingInfo(file: "b.m4a", start: Date(timeIntervalSince1970: 1_800_001_000), duration: 8, inProgress: false),
        ]
        session.markers = [Marker(recording: "b.m4a", time: 3, text: "Sınavda çıkar")]
        try library.save(session)
        return session
    }

    func testTranscribesInPiecesThenWritesNotesAndQuestions() async throws {
        let session = try makeSession()
        let transcriber = FakeTranscriber()
        let writer = FakeWriter()
        let processor = SessionProcessor(library: library, transcriber: transcriber,
                                         writer: .init(provider: writer, model: "m"), notesLanguage: "tr", pieceLength: 6)
        let seen = Seen()
        let outcome = try await processor.run(session, course: course) { seen.add($0) }
        XCTAssertEqual(outcome, SessionProcessor.Outcome())

        let folder = library.folder(of: session)
        let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
        // a.m4a is cut in its quiet middle; b.m4a starts at 14 s on the session timeline
        XCTAssertEqual(transcript, "[00:00:00]\nwords of a-0 in tr\n\n[00:00:07]\nwords of a-1 in tr\n\n[00:00:14]\nwords of b-0 in tr\n")
        XCTAssertEqual(transcriber.called.count, 3)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".lectern/pieces-6").path)
        XCTAssertEqual(Set(left), ["a-0.txt", "a-1.txt", "b-0.txt"])
        XCTAssertTrue(SessionProcessor.isUpToDate(session, in: library))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8), "# Geri yayılım\n## Giriş\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("questions.md"), encoding: .utf8), "# Sorular\n1. Ne?\n")

        let notesInput = try XCTUnwrap(writer.requests.first?.messages.first?.text)
        XCTAssertTrue(notesInput.contains("Course: Computer Vision"))
        XCTAssertTrue(notesInput.contains("[00:00:17] Sınavda çıkar"))
        XCTAssertTrue(notesInput.contains("Transcript:\n[00:00:00]"))
        XCTAssertTrue(writer.requests.first?.system.contains("Turkish") == true)
        XCTAssertEqual(writer.requests.last?.messages.first?.text, "# Geri yayılım\n## Giriş\n")
        XCTAssertEqual(seen.all.first, .preparing)
        XCTAssertTrue(seen.all.contains(.transcribing(done: 3, total: 3)))
        XCTAssertEqual(Array(seen.all.suffix(2)), [.writingNotes, .writingQuestions])
    }

    func testAnInterruptedRunKeepsFinishedPiecesAndRetriesTemporaryErrors() async throws {
        let session = try makeSession()
        let transcriber = FakeTranscriber()
        // the first answer is a rate limit with a short delay; the piece is tried again
        transcriber.failFirst = .rateLimited(retryAfter: 0.01, "slow down")
        let processor = SessionProcessor(library: library, transcriber: transcriber, writer: nil, notesLanguage: "tr",
                                         pieceLength: 6, parallel: 1)
        let outcome = try await processor.run(session, course: course) { _ in }
        XCTAssertEqual(outcome, SessionProcessor.Outcome(needsTranscriber: false, needsWriter: true))
        XCTAssertEqual(transcriber.called.count, 4)

        // a second run with a writer only writes; nothing is transcribed again
        let again = FakeTranscriber()
        let writer = FakeWriter()
        _ = try await SessionProcessor(library: library, transcriber: again, writer: .init(provider: writer, model: "m"),
                                       notesLanguage: "en", pieceLength: 6).run(session, course: course) { _ in }
        XCTAssertEqual(again.called, [])
        XCTAssertEqual(writer.requests.count, 2)
        XCTAssertTrue(writer.requests.first?.system.contains("English") == true)
    }

    func testPiecesAlreadyTranscribedAreNotSentAgain() async throws {
        let session = try makeSession()
        let folder = library.folder(of: session)
        let pieces = folder.appendingPathComponent(".lectern/pieces-6")
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        try "kept".write(to: pieces.appendingPathComponent("a-0.txt"), atomically: true, encoding: .utf8)
        let transcriber = FakeTranscriber()
        _ = try await SessionProcessor(library: library, transcriber: transcriber, writer: nil, notesLanguage: "tr",
                                       pieceLength: 6).run(session, course: course) { _ in }
        XCTAssertEqual(Set(transcriber.called), ["a-1.m4a", "b-0.m4a"])
        let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(transcript.hasPrefix("[00:00:00]\nkept\n\n"))
    }

    func testAPhotoAddedLaterRewritesOnlyTheNotes() async throws {
        var session = try makeSession()
        let writer = FakeWriter()
        let processor = SessionProcessor(library: library, transcriber: FakeTranscriber(), writer: .init(provider: writer, model: "m"),
                                         notesLanguage: "tr", pieceLength: 6)
        _ = try await processor.run(session, course: course) { _ in }
        XCTAssertEqual(writer.requests.count, 2)

        session.photos.append(BoardPhoto(file: "IMG_1.jpg", recording: "a.m4a", time: 3))
        try library.save(session)
        XCTAssertFalse(SessionProcessor.isUpToDate(session, in: library))
        // the processor reads the session again, so an older copy without the photo is enough
        _ = try await processor.run(try makeSessionCopyWithoutPhotos(session), course: course) { _ in }
        XCTAssertEqual(writer.requests.count, 3)
        XCTAssertTrue(writer.requests.last?.messages.first?.text.contains("[00:00:03] board/IMG_1.jpg") == true)
        XCTAssertTrue(SessionProcessor.isUpToDate(session, in: library))
    }

    private func makeSessionCopyWithoutPhotos(_ session: Session) throws -> Session {
        var copy = session
        copy.photos = []
        return copy
    }

    func testARecordingAddedLaterIsTranscribedAndTheNotesRewritten() async throws {
        var session = try makeSession()
        let writer = FakeWriter()
        let first = SessionProcessor(library: library, transcriber: FakeTranscriber(), writer: .init(provider: writer, model: "m"),
                                     notesLanguage: "tr", pieceLength: 6)
        _ = try await first.run(session, course: course) { _ in }
        XCTAssertEqual(writer.requests.count, 2)

        // the same lecture goes on later that day
        let folder = library.folder(of: session)
        try writeLecture(folder.appendingPathComponent("c.m4a"), seconds: 5, silences: [])
        session.recordings.append(RecordingInfo(file: "c.m4a", start: Date(timeIntervalSince1970: 1_800_002_000), duration: 5))
        try library.save(session)
        XCTAssertFalse(SessionProcessor.isUpToDate(session, in: library))

        let transcriber = FakeTranscriber()
        _ = try await SessionProcessor(library: library, transcriber: transcriber, writer: .init(provider: writer, model: "m"),
                                       notesLanguage: "tr", pieceLength: 6).run(session, course: course) { _ in }
        XCTAssertEqual(transcriber.called, ["c-0.m4a"])
        let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(transcript.hasSuffix("[00:00:22]\nwords of c-0 in tr\n"))
        XCTAssertEqual(writer.requests.count, 4)
        XCTAssertTrue(SessionProcessor.isUpToDate(session, in: library))
    }

    func testAnImportedTranscriptIsKeptWhenTheLectureGoesOn() async throws {
        var session = try makeSession()
        let folder = library.folder(of: session)
        // imported: text but no pieces, and the first recording's audio was not copied
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.m4a"))
        for name in ["transcript.txt", "notes.md", "questions.md"] {
            try "eski \(name)".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(SessionProcessor.isUpToDate(session, in: library))
        try writeLecture(folder.appendingPathComponent("c.m4a"), seconds: 5, silences: [])
        session.recordings.append(RecordingInfo(file: "c.m4a", start: Date(timeIntervalSince1970: 1_800_002_000), duration: 5))
        try library.save(session)

        let transcriber = FakeTranscriber()
        _ = try await SessionProcessor(library: library, transcriber: transcriber, writer: .init(provider: FakeWriter(), model: "m"),
                                       notesLanguage: "tr", pieceLength: 6).run(session, course: course) { _ in }
        XCTAssertEqual(transcriber.called, ["c-0.m4a"])
        let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
        // a's 14 s are counted from its saved duration, b's 8 s from the file
        XCTAssertEqual(transcript, "eski transcript.txt\n\n[00:00:22]\nwords of c-0 in tr\n")
        let backup = try String(contentsOf: folder.appendingPathComponent(".lectern/previous/notes.md"), encoding: .utf8)
        XCTAssertEqual(backup, "eski notes.md")
    }

    func testAWriterThatCannotBeReachedDoesNotHoldUpTheTranscript() async throws {
        let session = try makeSession()
        let processor = SessionProcessor(library: library, transcriber: FakeTranscriber(),
                                         findWriter: { throw ProviderError.network("offline") }, notesLanguage: "tr", pieceLength: 6)
        do {
            _ = try await processor.run(session, course: course) { _ in }
            XCTFail("expected the writer's error")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .network("offline"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.folder(of: session).appendingPathComponent("transcript.txt").path))
    }

    func testMissingLengthsAreReadFromTheFiles() throws {
        var session = try makeSession()
        session.recordings[0].duration = nil
        try library.save(session)
        XCTAssertEqual(library.completeDurations([session]), 1)
        XCTAssertEqual(library.reload(session)?.recordings[0].duration ?? 0, 14, accuracy: 0.1)
        // nothing left to fill
        XCTAssertEqual(library.completeDurations([library.reload(session)!]), 0)
    }

    func testAnImportedSessionCountsAsDone() throws {
        let session = try makeSession()
        let folder = library.folder(of: session)
        for name in ["transcript.txt", "notes.md", "questions.md"] {
            try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(SessionProcessor.isUpToDate(session, in: library))
    }

    func testWithoutAKeyNothingIsTouched() async throws {
        let session = try makeSession()
        let outcome = try await SessionProcessor(library: library, transcriber: nil, writer: nil, notesLanguage: "tr")
            .run(session, course: course) { _ in XCTFail("no progress expected") }
        XCTAssertEqual(outcome, SessionProcessor.Outcome(needsTranscriber: true, needsWriter: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.folder(of: session).appendingPathComponent("transcript.txt").path))
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProcessingProgress] = []

    var all: [ProcessingProgress] { lock.withLock { items } }

    func add(_ item: ProcessingProgress) { lock.withLock { items.append(item) } }
}
