import Foundation

/// An exam, deadline or other date the lecturer gave during a lecture, found in its transcript. Kept in
/// the session folder as `dates.json`; the student adds it to the course's dates or ignores it.
public struct MentionedDate: Codable, Hashable, Identifiable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case pending, added, ignored
    }

    public var id: UUID
    public var kind: CourseDate.Kind
    public var title: String
    public var date: Date
    /// The lecturer's words, as the transcript has them.
    public var quote: String
    /// Seconds into the session's recordings, played back to back, where it was said.
    public var at: TimeInterval?
    public var decision: Decision

    public init(id: UUID = UUID(), kind: CourseDate.Kind, title: String, date: Date, quote: String,
                at: TimeInterval? = nil, decision: Decision = .pending) {
        self.id = id
        self.kind = kind
        self.title = title
        self.date = date
        self.quote = quote
        self.at = at
        self.decision = decision
    }

    /// The course date it becomes when added; the same id, so adding twice keeps one.
    public var courseDate: CourseDate {
        CourseDate(id: id, kind: kind, title: title, date: date)
    }
}

extension Library {
    func datesURL(of session: Session) -> URL {
        folder(of: session).appendingPathComponent("dates.json")
    }

    /// The dates found in a lecture; empty when none were found or it was not looked at yet.
    public func mentionedDates(of session: Session) -> [MentionedDate] {
        (try? JSONStore.read([MentionedDate].self, from: datesURL(of: session))) ?? []
    }

    public func save(_ dates: [MentionedDate], for session: Session) throws {
        try JSONStore.write(dates, to: datesURL(of: session))
    }

    /// Adds a found date to its course, or sets it aside, and remembers the choice.
    @discardableResult
    public func decide(_ date: MentionedDate, in session: Session, add: Bool) throws -> Course? {
        var dates = mentionedDates(of: session)
        guard let index = dates.firstIndex(where: { $0.id == date.id }) else { return nil }
        dates[index].decision = add ? .added : .ignored
        var changed: Course?
        if add, let id = session.courseID, var course = courses().first(where: { $0.id == id }) {
            var events = course.dates ?? []
            events.removeAll { $0.id == date.id }
            events.append(dates[index].courseDate)
            course.dates = events
            try save(course)
            changed = course
        }
        try save(dates, for: session)
        return changed
    }
}
