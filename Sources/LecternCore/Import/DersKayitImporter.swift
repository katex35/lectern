import Foundation

/// Imports a folder made by the original command-line tool ("ders-kayit"): `dersler/program.json`,
/// `dersler/<CODE>/hafta-NN/` week folders and `toplantilar/<name>/` meetings. Files are copied;
/// the source is never modified.
public struct DersKayitImporter {
    public struct Summary: Equatable, Sendable {
        public var courses = 0
        public var sessions = 0
        public var recordings = 0
        public var markers = 0
        public var photos = 0
        public var skipped: [String] = []
    }

    public let source: URL
    public let library: Library
    public var defaultLanguage = "tr"
    private let fm = FileManager.default

    public init(source: URL, library: Library) {
        self.source = source
        self.library = library
    }

    /// True if `url` looks like an original tool folder.
    public static func canImport(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("dersler").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("toplantilar").path)
    }

    // MARK: legacy formats

    struct Program: Decodable {
        struct Slot: Decodable {
            var gun: Int
            var bas: String
            var bit: String
            var kod: String
            var ad: String
        }
        var donem_baslangic: String?
        var dersler: [Slot]
    }

    struct CourseFile: Decodable {
        var kod: String
        var ad: String
    }

    struct LegacyRecording: Decodable {
        var baslangic: String?
        var baslangic_elle: String?
        var bitis: String?
        var cihaz: String?
        var bosluklar: [LegacyGap]?
        var hata: String?
    }

    struct LegacyGap: Decodable {
        var bas: Double
        var uz: Double
        var neden: String
    }

    struct LegacyMarkers: Decodable {
        struct Item: Decodable {
            var kayit: String
            var t: Double
            var tur: String?
            var metin: String?
            var dosya: String?
            var eklendi: String?
        }
        var isaretler: [Item]
    }

    /// Plain-text documents and their new names.
    static let documents = [
        "transkript.txt": "transcript.txt", "not.md": "notes.md", "sorular.md": "questions.md",
        "ozet.md": "summary.md", "aksiyonlar.md": "actions.md", "tahta.md": "board.md", "notlarim.md": "my-notes.md",
    ]

    static let recordingPattern = try! NSRegularExpression(pattern: "^kayit(-\\d{4})?\\.m4a$")

    // MARK: import

    public func run() throws -> Summary {
        var summary = Summary()
        let dersler = source.appendingPathComponent("dersler")
        var program: Program?
        if let data = try? Data(contentsOf: dersler.appendingPathComponent("program.json")) {
            program = try? JSONDecoder().decode(Program.self, from: data)
        }

        // courses: program.json slots, plus folders that only have a ders.json
        var courses: [String: Course] = [:]
        for slot in program?.dersler ?? [] {
            guard let start = ClockTime(slot.bas), let end = ClockTime(slot.bit) else { continue }
            var c = courses[slot.kod] ?? Course(id: Course.sanitizedID(slot.kod), name: slot.ad, language: defaultLanguage)
            c.slots.append(ScheduleSlot(weekday: slot.gun, start: start, end: end))
            courses[slot.kod] = c
        }
        for folder in subfolders(dersler) {
            let code = folder.lastPathComponent
            if courses[code] == nil {
                let file = try? JSONDecoder().decode(CourseFile.self, from: Data(contentsOf: folder.appendingPathComponent("ders.json")))
                courses[code] = Course(id: Course.sanitizedID(code), name: file?.ad ?? code, language: defaultLanguage)
            }
        }
        for course in courses.values {
            if !library.courses().contains(where: { $0.id == course.id }) {
                try library.save(course)
                summary.courses += 1
            }
        }
        if let text = program?.donem_baslangic, library.settings().semester == nil,
           let start = Self.dayFormatter.date(from: text) {
            var settings = library.settings()
            settings.semester = Semester(name: "", start: start)
            try library.save(settings)
        }

        for (code, course) in courses {
            for week in subfolders(dersler.appendingPathComponent(code))
            where week.lastPathComponent.hasPrefix("hafta-") {
                let number = Int(week.lastPathComponent.dropFirst("hafta-".count))
                try importFolder(week, kind: .lecture, course: course, week: number, summary: &summary)
            }
        }
        for meeting in subfolders(source.appendingPathComponent("toplantilar")) {
            try importFolder(meeting, kind: .meeting, course: nil, week: nil, summary: &summary)
        }
        return summary
    }

    private func importFolder(_ folder: URL, kind: SessionKind, course: Course?, week: Int?, summary: inout Summary) throws {
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let recordingNames = names.filter {
            Self.recordingPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }
        let legacy = (try? JSONDecoder().decode([String: LegacyRecording].self,
                                                from: Data(contentsOf: folder.appendingPathComponent("kayitlar.json")))) ?? [:]

        var recordings: [RecordingInfo] = []
        for name in recordingNames {
            let file = folder.appendingPathComponent(name)
            let meta = legacy[name]
            let start = (meta?.baslangic_elle ?? meta?.baslangic).flatMap(Self.parseDate)
                ?? ((try? fm.attributesOfItem(atPath: file.path)[.creationDate]) as? Date) ?? Date()
            let end = meta?.bitis.flatMap(Self.parseDate)
            let gaps = (meta?.bosluklar ?? []).map { g in
                RecordingGap(start: g.bas, duration: g.uz, reason: g.neden == "yazici tikandi" ? .writerStalled
                             : g.neden == "tampon dustu" ? .droppedBuffer : .noInput)
            }
            // without an end in the old notes, the file itself knows how long it is
            let duration = end.map { $0.timeIntervalSince(start) } ?? AudioLength.seconds(of: file)
            recordings.append(RecordingInfo(file: name, start: start, duration: duration,
                                            device: meta?.cihaz, gaps: gaps, problem: meta?.hata))
        }
        guard let first = recordings.map(\.start).min() else {
            summary.skipped.append(folder.lastPathComponent)
            return
        }

        var session: Session
        if kind == .lecture, let course {
            session = try library.lectureSession(course: course, date: first, week: week)
        } else {
            let title = folder.lastPathComponent
            if let existing = library.meetings().first(where: { $0.title == title }) {
                session = existing
            } else {
                session = try library.newMeeting(title: title, date: first)
                session.title = title
            }
        }
        let target = library.folder(of: session)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        for info in recordings where !session.recordings.contains(where: { $0.file == info.file }) {
            try copy(folder.appendingPathComponent(info.file), to: target.appendingPathComponent(info.file))
            session.recordings.append(info)
            summary.recordings += 1
        }
        for (old, new) in Self.documents where names.contains(old) {
            try copy(folder.appendingPathComponent(old), to: target.appendingPathComponent(new))
        }
        if let markers = try? JSONDecoder().decode(LegacyMarkers.self,
                                                   from: Data(contentsOf: folder.appendingPathComponent("isaretler.json"))) {
            for m in markers.isaretler {
                let created = m.eklendi.flatMap(Self.parseDate) ?? first
                if m.tur == "foto", let path = m.dosya {
                    let file = (path as NSString).lastPathComponent
                    guard !session.photos.contains(where: { $0.file == file }) else { continue }
                    try copy(folder.appendingPathComponent(path), to: target.appendingPathComponent("board/\(file)"))
                    session.photos.append(BoardPhoto(file: file, recording: m.kayit, time: m.t))
                    summary.photos += 1
                } else if let text = m.metin, !text.isEmpty {
                    guard !session.markers.contains(where: { $0.recording == m.kayit && $0.time == m.t && $0.text == text })
                    else { continue }
                    session.markers.append(Marker(recording: m.kayit, time: m.t, text: text, created: created))
                    summary.markers += 1
                }
            }
        }
        // board photos that were never placed on the timeline
        let board = folder.appendingPathComponent("tahta")
        for photo in ((try? fm.contentsOfDirectory(atPath: board.path)) ?? []).sorted()
        where !photo.hasPrefix(".") && !session.photos.contains(where: { $0.file == photo }) {
            try copy(board.appendingPathComponent(photo), to: target.appendingPathComponent("board/\(photo)"))
            session.photos.append(BoardPhoto(file: photo))
            summary.photos += 1
        }
        try library.save(session)
        summary.sessions += 1
    }

    private func copy(_ from: URL, to: URL) throws {
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: from, to: to)
    }

    private func subfolders(_ url: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
}
