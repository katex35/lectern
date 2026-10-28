import AVFoundation
import Foundation

/// Where a session's processing is.
public enum ProcessingProgress: Equatable, Sendable {
    case preparing
    case transcribing(done: Int, total: Int)
    case writingNotes
    case writingQuestions
}

/// Speech to text for one piece of audio; `GeminiTranscriber` in the app, a stand-in in tests.
public protocol Transcribing: Sendable {
    func transcribe(_ audio: URL, languages: [String], vocabulary: [String]) async throws -> String
}

extension GeminiTranscriber: Transcribing {}

/// Turns a session's recordings into `transcript.txt`, then writes `notes.md` and `questions.md`
/// with the user's chosen model. Each step is skipped when its file exists, and finished pieces are
/// kept, so an interrupted run continues where it stopped.
public struct SessionProcessor: Sendable {
    public struct Writer: Sendable {
        public var provider: any LanguageModelProvider
        public var model: String

        public init(provider: any LanguageModelProvider, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    /// What is still missing after a run because nothing could make it.
    public struct Outcome: Equatable, Sendable {
        public var needsTranscriber = false
        public var needsWriter = false
    }

    let library: Library
    let transcriber: (any Transcribing)?
    let writer: Writer?
    /// The language notes and questions are written in, as a BCP 47 code.
    let notesLanguage: String
    let pieceLength: TimeInterval
    let parallel: Int

    public init(library: Library, transcriber: (any Transcribing)?, writer: Writer?, notesLanguage: String,
                pieceLength: TimeInterval = 300, parallel: Int = 3) {
        self.library = library
        self.transcriber = transcriber
        self.writer = writer
        self.notesLanguage = notesLanguage
        self.pieceLength = pieceLength
        self.parallel = parallel
    }

    public func run(_ session: Session, course: Course?,
                    progress: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> Outcome {
        let folder = library.folder(of: session)
        var outcome = Outcome()
        var state = Self.state(of: session, in: folder)
        let transcriptURL = folder.appendingPathComponent("transcript.txt")
        if !state.transcriptCurrent {
            guard let transcriber else {
                outcome.needsTranscriber = true
                outcome.needsWriter = writer == nil
                return outcome
            }
            progress(.preparing)
            let transcript = try await transcribe(session, course: course, folder: folder, with: transcriber, progress: progress)
            try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            state.manifest.transcript = state.recordings
            try state.manifest.save(in: folder)
            // the text of each piece is kept, the cut audio is only needed until now
            let pieces = piecesFolder(folder)
            for file in (try? FileManager.default.contentsOfDirectory(at: pieces, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "m4a" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""

        let notesURL = folder.appendingPathComponent("notes.md")
        let questionsURL = folder.appendingPathComponent("questions.md")
        // notes from an older transcript are written again, and questions follow the notes
        let needsNotes = !FileManager.default.fileExists(atPath: notesURL.path) || state.manifest.notes != state.manifest.transcript
        let needsQuestions = needsNotes || !FileManager.default.fileExists(atPath: questionsURL.path)
            || state.manifest.questions != state.manifest.transcript
        guard needsNotes || needsQuestions else { return outcome }
        guard let writer else {
            outcome.needsWriter = true
            return outcome
        }
        if needsNotes {
            progress(.writingNotes)
            let notes = try await write(writer, system: NotePrompts.notes(language: notesLanguage),
                                        input: NotePrompts.lecture(session: session, course: course, transcript: transcript),
                                        limit: 16000)
            try notes.write(to: notesURL, atomically: true, encoding: .utf8)
            state.manifest.notes = state.manifest.transcript
            try state.manifest.save(in: folder)
        }
        if needsQuestions {
            progress(.writingQuestions)
            let notes = (try? String(contentsOf: notesURL, encoding: .utf8)) ?? transcript
            let questions = try await write(writer, system: NotePrompts.questions(language: notesLanguage),
                                            input: notes, limit: 8000)
            try questions.write(to: questionsURL, atomically: true, encoding: .utf8)
            state.manifest.questions = state.manifest.transcript
            try state.manifest.save(in: folder)
        }
        return outcome
    }

    // MARK: what is done

    /// Which recordings the transcript, notes and questions were made from.
    struct Manifest: Codable, Equatable {
        var transcript: [String]
        var notes: [String]?
        var questions: [String]?

        static func url(in folder: URL) -> URL { folder.appendingPathComponent(".lectern/made-from.json") }

        func save(in folder: URL) throws {
            let url = Self.url(in: folder)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    struct State {
        /// Finished recordings, in order.
        var recordings: [String]
        var manifest: Manifest
        var transcriptCurrent: Bool
    }

    static func state(of session: Session, in folder: URL) -> State {
        let recordings = session.orderedRecordings.filter { !$0.inProgress }.map(\.file)
        let exists = { (name: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        let manifest: Manifest
        if let data = try? Data(contentsOf: Manifest.url(in: folder)), let saved = try? JSONDecoder().decode(Manifest.self, from: data) {
            manifest = saved
        } else if exists("transcript.txt") {
            // made before Lectern kept track (an import): take it as covering what is there
            manifest = Manifest(transcript: recordings, notes: exists("notes.md") ? recordings : nil,
                                questions: exists("questions.md") ? recordings : nil)
            try? manifest.save(in: folder)
        } else {
            manifest = Manifest(transcript: [])
        }
        let current = exists("transcript.txt") && Set(recordings).isSubset(of: manifest.transcript)
        return State(recordings: recordings, manifest: manifest, transcriptCurrent: current)
    }

    /// True when every finished recording is in the transcript and the notes and questions follow it.
    public static func isUpToDate(_ session: Session, in library: Library) -> Bool {
        let folder = library.folder(of: session)
        let state = state(of: session, in: folder)
        let exists = { (name: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        return state.transcriptCurrent && exists("notes.md") && exists("questions.md")
            && state.manifest.notes == state.manifest.transcript && state.manifest.questions == state.manifest.transcript
    }

    // MARK: transcript

    func piecesFolder(_ folder: URL) -> URL {
        folder.appendingPathComponent(".lectern/pieces", isDirectory: true)
    }

    struct Piece: Sendable {
        var chunk: AudioChunk
        /// Seconds on the session timeline, all recordings back to back.
        var start: TimeInterval
        var text: URL
    }

    func transcribe(_ session: Session, course: Course?, folder: URL, with transcriber: any Transcribing,
                    progress: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> String {
        let pieces = piecesFolder(folder)
        var all: [Piece] = []
        var offset: TimeInterval = 0
        for recording in session.orderedRecordings where !recording.inProgress {
            let source = folder.appendingPathComponent(recording.file)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let text = { (piece: URL) in piece.deletingPathExtension().appendingPathExtension("txt") }
            let chunks = try await AudioChunker.split(source, length: pieceLength, into: pieces) {
                !FileManager.default.fileExists(atPath: text($0).path)
            }
            for chunk in chunks {
                all.append(Piece(chunk: chunk, start: offset + chunk.start, text: text(chunk.url)))
            }
            offset += chunks.reduce(0) { $0 + $1.duration }
        }
        guard !all.isEmpty else { throw ProcessingError.noAudio }

        let languages = course.map { [$0.language] } ?? []
        let vocabulary = [course?.name, course?.instructor].compactMap { $0 }
        let total = all.count
        let counter = Counter(done: all.filter { FileManager.default.fileExists(atPath: $0.text.path) }.count)
        progress(.transcribing(done: await counter.done, total: total))

        let waiting = all.filter { !FileManager.default.fileExists(atPath: $0.text.path) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = waiting.makeIterator()
            func add(_ piece: Piece) {
                group.addTask {
                    let text = try await retrying { try await transcriber.transcribe(piece.chunk.url, languages: languages, vocabulary: vocabulary) }
                    try text.write(to: piece.text, atomically: true, encoding: .utf8)
                    progress(.transcribing(done: await counter.add(), total: total))
                }
            }
            for _ in 0..<max(1, parallel) {
                guard let piece = next.next() else { break }
                add(piece)
            }
            while try await group.next() != nil {
                if let piece = next.next() { add(piece) }
            }
        }

        return all.compactMap { piece -> String? in
            guard let text = try? String(contentsOf: piece.text, encoding: .utf8), !text.isEmpty else { return nil }
            return "[\(Self.stamp(piece.start))]\n\(text)"
        }.joined(separator: "\n\n") + "\n"
    }

    /// 1:05:00 as "01:05:00".
    static func stamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private actor Counter {
        var done: Int

        init(done: Int) { self.done = done }

        func add() -> Int {
            done += 1
            return done
        }
    }

    // MARK: writing

    func write(_ writer: Writer, system: String, input: String, limit: Int) async throws -> String {
        let request = CompletionRequest(model: writer.model, system: system, messages: [ChatMessage(.user, input)],
                                        maxOutputTokens: limit)
        let (text, _) = try await retrying { try await writer.provider.complete(request) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.invalidResponse("The answer was empty") }
        return trimmed + "\n"
    }
}

/// Runs `body` again after a temporary failure: when told, after the server's delay, otherwise after
/// 2, 4 and 8 seconds. A usage limit or a rejected key is not retried.
func retrying<T: Sendable>(attempts: Int = 4, _ body: @Sendable () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await body()
        } catch let error as ProviderError where error.isTemporary && attempt + 1 < attempts {
            attempt += 1
            var delay = pow(2, Double(attempt))
            if case .rateLimited(let after?, _) = error { delay = min(120, max(delay, after)) }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

public enum ProcessingError: Error, Equatable, LocalizedError {
    case noAudio

    public var errorDescription: String? {
        switch self {
        case .noAudio: return "There is no finished recording to transcribe"
        }
    }
}
