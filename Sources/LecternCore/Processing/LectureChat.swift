import Foundation

/// One turn of a conversation about a lecture.
public struct ChatEntry: Codable, Equatable, Sendable {
    public var role: ChatMessage.Role
    public var text: String
    public var date: Date

    public init(role: ChatMessage.Role, text: String, date: Date = Date()) {
        self.role = role
        self.text = text
        self.date = date
    }
}

/// Questions about one lecture, answered from its notes and transcript. The conversation is kept in
/// the session folder as `chat.json`.
public enum LectureChat {
    static func url(in folder: URL) -> URL { folder.appendingPathComponent("chat.json") }

    public static func load(from folder: URL) -> [ChatEntry] {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return [] }
        return (try? JSONStore.decoder.decode([ChatEntry].self, from: data)) ?? []
    }

    public static func save(_ entries: [ChatEntry], in folder: URL) throws {
        try JSONStore.write(entries, to: url(in: folder))
    }

    /// The request for the answer to the last question in `entries`.
    public static func request(model: String, entries: [ChatEntry], session: Session, course: Course?,
                               notes: String?, transcript: String?) -> CompletionRequest {
        CompletionRequest(model: model, system: system(session: session, course: course, notes: notes, transcript: transcript),
                          messages: entries.map { ChatMessage($0.role, $0.text) }, maxOutputTokens: 4000)
    }

    static func system(session: Session, course: Course?, notes: String?, transcript: String?) -> String {
        var parts = ["""
        You answer a student's questions about one lecture they recorded. Answer in the language of the question, \
        briefly and clearly, from the lecture's notes and transcript below. When the lecture did not cover \
        something, say so in one sentence, then answer from general knowledge and say that it is. Use Markdown; \
        formulas in LaTeX, \\( ... \\) inside a sentence and \\[ ... \\] on lines of their own.
        """]
        parts.append(course.map { "Course: \($0.name)" } ?? "Meeting: \(session.title)")
        if let notes, !notes.isEmpty { parts.append("Notes:\n" + notes) }
        if let transcript, !transcript.isEmpty { parts.append("Transcript:\n" + transcript) }
        return parts.joined(separator: "\n\n")
    }
}
