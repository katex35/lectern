import Foundation

/// JSON with ISO 8601 dates (fractional seconds kept), written atomically.
public enum JSONStore {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(withFraction.string(from: date))
        }
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let text = try dec.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(text)"))
        }
        return d
    }()

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }
}

/// The user's library: plain folders they own and can back up, sync or open in Finder.
///
///     <root>/library.json
///     <root>/Courses/<CODE>/course.json
///     <root>/Courses/<CODE>/<YYYY-MM-DD> Week NN/session.json, recording-HHmmss.m4a, board/
///     <root>/Meetings/<YYYY-MM-DD HHmm> <title>/session.json, ...
public final class Library: @unchecked Sendable {
    public struct Settings: Codable, Hashable, Sendable {
        public var semester: Semester?
        public var version: Int

        public init(semester: Semester? = nil, version: Int = 1) {
            self.semester = semester
            self.version = version
        }
    }

    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Lectern")
    }

    public var coursesFolder: URL { root.appendingPathComponent("Courses", isDirectory: true) }
    public var meetingsFolder: URL { root.appendingPathComponent("Meetings", isDirectory: true) }
    var settingsURL: URL { root.appendingPathComponent("library.json") }

    // MARK: settings

    public func settings() -> Settings {
        (try? JSONStore.read(Settings.self, from: settingsURL)) ?? Settings()
    }

    public func save(_ settings: Settings) throws {
        try JSONStore.write(settings, to: settingsURL)
    }

    // MARK: courses

    public func folder(ofCourse id: String) -> URL {
        coursesFolder.appendingPathComponent(id, isDirectory: true)
    }

    public func courses() -> [Course] {
        subfolders(of: coursesFolder)
            .compactMap { try? JSONStore.read(Course.self, from: $0.appendingPathComponent("course.json")) }
            .sorted { $0.id < $1.id }
    }

    public func save(_ course: Course) throws {
        try JSONStore.write(course, to: folder(ofCourse: course.id).appendingPathComponent("course.json"))
    }

    // MARK: sessions

    public func folder(of session: Session) -> URL {
        let parent = session.kind == .meeting ? meetingsFolder : folder(ofCourse: session.courseID ?? "_")
        return parent.appendingPathComponent(session.id, isDirectory: true)
    }

    public func sessions(ofCourse id: String) -> [Session] {
        loadSessions(in: folder(ofCourse: id))
    }

    public func meetings() -> [Session] {
        loadSessions(in: meetingsFolder)
    }

    public func save(_ session: Session) throws {
        try JSONStore.write(session, to: folder(of: session).appendingPathComponent("session.json"))
    }

    public func reload(_ session: Session) -> Session? {
        try? JSONStore.read(Session.self, from: folder(of: session).appendingPathComponent("session.json"))
    }

    /// The lecture session of `course` on the day of `date`. A second recording on the same day (after a
    /// break) joins the same session, like `kayit-SSDD.m4a` did in the original tool.
    public func lectureSession(course: Course, date: Date, week: Int?, calendar: Calendar = .current) throws -> Session {
        let day = Self.dayFormatter(calendar).string(from: date)
        if let existing = sessions(ofCourse: course.id).first(where: { $0.id.hasPrefix(day) }) {
            return existing
        }
        let id = week.map { String(format: "%@ Week %02d", day, $0) } ?? day
        let session = Session(id: id, kind: .lecture, courseID: course.id, title: course.name,
                              date: date, week: week)
        try save(session)
        return session
    }

    public func newMeeting(title: String, date: Date, calendar: Calendar = .current) throws -> Session {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        let cleanTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        var id = cleanTitle.isEmpty ? f.string(from: date) : "\(f.string(from: date)) \(cleanTitle)"
        var n = 2
        while fm.fileExists(atPath: meetingsFolder.appendingPathComponent(id).path) {
            id = "\(f.string(from: date)) \(cleanTitle) \(n)"
            n += 1
        }
        let session = Session(id: id, kind: .meeting, courseID: nil, title: cleanTitle.isEmpty ? id : cleanTitle,
                              date: date)
        try save(session)
        return session
    }

    /// A new, unused recording file name in the session folder, named after its start time.
    public func newRecordingFile(in session: Session, start: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        let base = "recording-\(f.string(from: start))"
        var name = "\(base).m4a"
        var n = 2
        while fm.fileExists(atPath: folder(of: session).appendingPathComponent(name).path) {
            name = "\(base)-\(n).m4a"
            n += 1
        }
        return name
    }

    // MARK: helpers

    static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private func subfolders(of url: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                      options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func loadSessions(in url: URL) -> [Session] {
        subfolders(of: url)
            .compactMap { try? JSONStore.read(Session.self, from: $0.appendingPathComponent("session.json")) }
            .sorted { $0.date > $1.date }
    }
}
