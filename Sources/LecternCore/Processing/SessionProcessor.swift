import AVFoundation
import Foundation

/// Where a session's processing is.
public enum ProcessingProgress: Equatable, Sendable {
    case preparing
    case transcribing(done: Int, total: Int)
    case writingNotes
    case writingQuestions
    case findingDates
}

/// Speech to text for one piece of audio; `GeminiTranscriber` in the app, a stand-in in tests.
public protocol Transcribing: Sendable {
    func transcribe(_ audio: URL, languages: [String], vocabulary: [String]) async throws -> String
}

extension GeminiTranscriber: Transcribing {}

/// Turns a session's recordings into `transcript.txt`, then writes `notes.md` and `questions.md`
/// with the user's chosen model and lists the dates the lecturer gave in `dates.json`. Each step is skipped when its file exists, and finished pieces are
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
    /// Found only when notes are due, so an account that cannot be reached does not hold up the transcript.
    let writer: @Sendable () async throws -> Writer?
    /// The language notes and questions are written in, as a BCP 47 code.
    let notesLanguage: String
    let pieceLength: TimeInterval
    let parallel: Int

    public init(library: Library, transcriber: (any Transcribing)?, writer: Writer?, notesLanguage: String,
                pieceLength: TimeInterval = 300, parallel: Int = 3) {
        self.init(library: library, transcriber: transcriber, findWriter: { writer }, notesLanguage: notesLanguage,
                  pieceLength: pieceLength, parallel: parallel)
    }

    public init(library: Library, transcriber: (any Transcribing)?, findWriter: @escaping @Sendable () async throws -> Writer?,
                notesLanguage: String, pieceLength: TimeInterval = 300, parallel: Int = 3) {
        self.library = library
        self.transcriber = transcriber
        self.writer = findWriter
        self.notesLanguage = notesLanguage
        self.pieceLength = pieceLength
        self.parallel = parallel
    }

    public func run(_ session: Session, course: Course?,
                    progress: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> Outcome {
        // photos and notes added since the caller read the session count too
        let session = library.reload(session) ?? session
        let folder = library.folder(of: session)
        var outcome = Outcome()
        var state = Self.state(of: session, in: folder)
        let transcriptURL = folder.appendingPathComponent("transcript.txt")
        if !state.transcriptCurrent {
            guard let transcriber else {
                outcome.needsTranscriber = true
                outcome.needsWriter = ((try? await writer()) ?? nil) == nil
                return outcome
            }
            progress(.preparing)
            let earlier = try? String(contentsOf: transcriptURL, encoding: .utf8)
            let transcript = try await transcribe(session, course: course, folder: folder, with: transcriber,
                                                  keeping: earlier, covered: Set(state.manifest.transcript), progress: progress)
            try replace(transcriptURL, with: transcript, in: folder)
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
        // notes from an older transcript, or without the latest photos, are written again; questions follow
        // the transcript only, since a photo changes where pictures sit in the notes, not what to ask
        let needsNotes = !FileManager.default.fileExists(atPath: notesURL.path) || !state.notesCurrent
        let needsQuestions = !FileManager.default.fileExists(atPath: questionsURL.path)
            || state.manifest.questions != state.manifest.transcript
        let needsDates = course != nil && state.manifest.dates != state.manifest.transcript
        guard needsNotes || needsQuestions || needsDates else { return outcome }
        guard let writer = try await writer() else {
            outcome.needsWriter = true
            return outcome
        }
        if needsNotes {
            progress(.writingNotes)
            let notes = try await write(writer, system: NotePrompts.notes(language: notesLanguage),
                                        input: NotePrompts.lecture(session: session, course: course, transcript: transcript),
                                        limit: 16000)
            try replace(notesURL, with: notes, in: folder)
            state.manifest.notes = state.manifest.transcript
            state.manifest.notesPhotos = state.photos
            try state.manifest.save(in: folder)
        }
        if needsQuestions {
            progress(.writingQuestions)
            let notes = (try? String(contentsOf: notesURL, encoding: .utf8)) ?? transcript
            let questions = try await write(writer, system: NotePrompts.questions(language: notesLanguage),
                                            input: notes, limit: 8000)
            try replace(questionsURL, with: questions, in: folder)
            state.manifest.questions = state.manifest.transcript
            try state.manifest.save(in: folder)
        }
        if needsDates {
            progress(.findingDates)
            // the notes are what the run is for; dates that could not be read now are tried again later
            try? await findDates(session, course: course, transcript: transcript, writer: writer, folder: folder,
                                 from: state.manifest.transcript)
        }
        return outcome
    }

    /// Lectures whose transcript has not been read for dates yet; meetings have no course to add them to.
    public static func needsDates(_ session: Session, in library: Library) -> Bool {
        guard session.courseID != nil, session.kind != .meeting, !session.isRecording else { return false }
        let state = state(of: session, in: library.folder(of: session))
        return state.transcriptCurrent && state.manifest.dates != state.manifest.transcript
    }

    /// Reads an already transcribed lecture for dates, without touching its notes.
    public func findDates(_ session: Session, course: Course?) async throws {
        let session = library.reload(session) ?? session
        let folder = library.folder(of: session)
        let state = Self.state(of: session, in: folder)
        guard state.transcriptCurrent, let transcript = try? String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8),
              let writer = try await writer() else { return }
        try await findDates(session, course: course, transcript: transcript, writer: writer, folder: folder,
                            from: state.manifest.transcript)
    }

    /// - Parameter recordings: what `transcript` was made from, recorded as what the dates were read from.
    private func findDates(_ session: Session, course: Course?, transcript: String, writer: Writer, folder: URL,
                           from recordings: [String]) async throws {
        let answer = try await write(writer, system: LectureDates.prompt(language: notesLanguage),
                                     input: NotePrompts.lecture(session: session, course: course, transcript: transcript), limit: 2000)
        let found = LectureDates.parse(answer, lectureDate: session.date, transcript: transcript)
        try library.save(LectureDates.merge(found, keeping: library.mentionedDates(of: session)), for: session)
        // read again: another run may have written notes or a new transcript while the model was answering
        var manifest = Self.state(of: library.reload(session) ?? session, in: folder).manifest
        manifest.dates = recordings
        try manifest.save(in: folder)
    }

    // MARK: what is done

    /// Which recordings the transcript, notes and questions were made from.
    struct Manifest: Codable, Equatable {
        var transcript: [String]
        var notes: [String]?
        /// The board photos placed in the notes; missing for notes made before photos were tracked.
        var notesPhotos: [String]?
        var questions: [String]?
        /// What `dates.json` was read from.
        var dates: [String]?

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
        /// Board photos with a place on the timeline.
        var photos: [String]

        /// The notes follow the transcript and hold the photos taken so far.
        var notesCurrent: Bool {
            manifest.notes == manifest.transcript && (manifest.notesPhotos.map { Set($0) == Set(photos) } ?? true)
        }
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
        let photos = session.photos.filter { $0.recording != nil && $0.time != nil }.map(\.file).sorted()
        return State(recordings: recordings, manifest: manifest, transcriptCurrent: current, photos: photos)
    }

    /// True when every finished recording is in the transcript and the notes and questions follow it.
    public static func isUpToDate(_ session: Session, in library: Library) -> Bool {
        let folder = library.folder(of: session)
        let state = state(of: session, in: folder)
        let exists = { (name: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        return state.transcriptCurrent && exists("notes.md") && exists("questions.md")
            && state.notesCurrent && state.manifest.questions == state.manifest.transcript
    }

    // MARK: transcript

    /// Named after the piece length: pieces cut to another length cover other stretches of time.
    func piecesFolder(_ folder: URL) -> URL {
        folder.appendingPathComponent(".lectern/pieces-\(Int(pieceLength))", isDirectory: true)
    }

    /// Writes `text` to `url`, keeping the file it replaces in `.lectern/previous` so a hand edit is never just lost.
    func replace(_ url: URL, with text: String, in folder: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = folder.appendingPathComponent(".lectern/previous", isDirectory: true)
            try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
            let backup = previous.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: url, to: backup)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    struct Piece: Sendable {
        var chunk: AudioChunk
        /// Seconds on the session timeline, all recordings back to back.
        var start: TimeInterval
        var text: URL
    }

    /// - Parameters:
    ///   - earlier: the transcript there is now. Recordings it covers that have no pieces of their own
    ///     (an imported lecture, perhaps without its audio) keep this text instead of being transcribed again.
    ///   - covered: the recordings `earlier` was made from.
    func transcribe(_ session: Session, course: Course?, folder: URL, with transcriber: any Transcribing,
                    keeping earlier: String? = nil, covered: Set<String> = [],
                    progress: @escaping @Sendable (ProcessingProgress) -> Void) async throws -> String {
        let pieces = piecesFolder(folder)
        let cached = Set(((try? FileManager.default.contentsOfDirectory(atPath: pieces.path)) ?? []).filter { $0.hasSuffix(".txt") })
        var kept: String?
        var all: [Piece] = []
        var offset: TimeInterval = 0
        for recording in session.orderedRecordings where !recording.inProgress {
            let source = folder.appendingPathComponent(recording.file)
            let exists = FileManager.default.fileExists(atPath: source.path)
            let base = (recording.file as NSString).deletingPathExtension
            if let earlier, covered.contains(recording.file), !cached.contains(where: { $0.hasPrefix("\(base)-") }) {
                kept = earlier
                let length = exists ? (try? await AVURLAsset(url: source).load(.duration).seconds) : nil
                offset += length ?? recording.duration ?? 0
                continue
            }
            guard exists else { continue }
            let text = { (piece: URL) in piece.deletingPathExtension().appendingPathExtension("txt") }
            let chunks = try await AudioChunker.split(source, length: pieceLength, into: pieces) {
                !FileManager.default.fileExists(atPath: text($0).path)
            }
            for chunk in chunks {
                all.append(Piece(chunk: chunk, start: offset + chunk.start, text: text(chunk.url)))
            }
            offset += chunks.reduce(0) { $0 + $1.duration }
        }
        guard !all.isEmpty || kept != nil else { throw ProcessingError.noAudio }

        // a course without a set language lets the model detect it
        let languages = [course?.language].compactMap { $0 }.filter { !$0.isEmpty }
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

        let new = all.compactMap { piece -> String? in
            guard let text = try? String(contentsOf: piece.text, encoding: .utf8), !text.isEmpty else { return nil }
            return "[\(Self.stamp(piece.start))]\n\(text)"
        }
        let parts = [kept?.trimmingCharacters(in: .whitespacesAndNewlines)].compactMap { $0 }.filter { !$0.isEmpty } + new
        return parts.joined(separator: "\n\n") + "\n"
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
public func retrying<T: Sendable>(attempts: Int = 4, _ body: @Sendable () async throws -> T) async throws -> T {
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
