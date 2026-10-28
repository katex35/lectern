import Foundation

/// A practice question and its answer, taken from a lecture's `questions.md`.
public struct PracticeCard: Hashable, Identifiable, Sendable {
    /// "<session folder>#<number>", stable while the file keeps its numbering.
    public var id: String
    public var number: Int
    /// Markdown: the question's title line, then its body (choices, parts).
    public var question: String
    /// Markdown; empty when the file gives none.
    public var answer: String
}

public enum PracticeCards {
    /// Reads both shapes questions come in: Lectern's own ("1. Question" with its answer quoted below it),
    /// and the longer one with "### 1. Title" questions, an answer key ("1. **B:** ...") and
    /// "#### 9. Expected answer" sections further down. Numbers under an answers heading, or in another
    /// style than the question with that number, are answers; numbering that starts again in a new part
    /// of the questions gives new questions.
    public static func parse(_ source: String, prefix: String) -> [PracticeCard] {
        struct Block {
            var number: Int
            var heading: Bool
            var first: String
            var isAnswer: Bool
            var lines: [String] = []
        }
        var blocks: [Block] = []
        var current: Block?
        /// The level of the heading the answers sit under, while inside it.
        var answersLevel: Int?
        let close = {
            if let block = current { blocks.append(block) }
            current = nil
        }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let start = numbered(raw) {
                // an indented item, or one inside a heading's block, is part of the text: choices, steps
                let indented = raw.first == " " || raw.first == "\t"
                if start.heading || (!indented && current?.heading != true) {
                    close()
                    current = Block(number: start.number, heading: start.heading, first: start.text,
                                    isAnswer: answersLevel != nil || (start.heading && namesAnswers(start.text)))
                    continue
                }
            } else if line.hasPrefix("#") {
                close()
                let level = line.prefix(while: { $0 == "#" }).count
                if namesAnswers(String(line.dropFirst(level))) {
                    answersLevel = min(answersLevel ?? level, level)
                } else if let answers = answersLevel, level <= answers {
                    answersLevel = nil
                }
                continue
            }
            current?.lines.append(raw)
        }
        close()

        var cards: [PracticeCard] = []
        var styles: [String: Bool] = [:]
        for block in blocks {
            let quote = { (line: String) -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else { return nil }
                return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // a repeat in another style than its question (a "1. **B:**" key after "### 1." questions) answers it
            let open = cards.firstIndex { $0.number == block.number && $0.answer.isEmpty }
            let otherStyle = open.map { styles[cards[$0].id] != block.heading } ?? false
            if block.isAnswer || otherStyle {
                guard let at = open ?? cards.lastIndex(where: { $0.number == block.number }) else { continue }
                // a heading such as "Expected answer" says nothing itself
                let text = (block.heading ? [] : [block.first]) + block.lines.map { quote($0) ?? $0 }
                cards[at].answer = join(cards[at].answer, tidy(text.joined(separator: "\n")))
                continue
            }
            let body = block.lines.filter { quote($0) == nil }
            let title = block.heading ? "**\(block.first)**" : block.first
            let repeats = cards.filter { $0.number == block.number }.count
            let id = repeats == 0 ? "\(prefix)#\(block.number)" : "\(prefix)#\(block.number)-\(repeats + 1)"
            styles[id] = block.heading
            cards.append(PracticeCard(id: id, number: block.number,
                                      question: tidy(([title] + body).joined(separator: "\n")),
                                      answer: tidy(block.lines.compactMap(quote).joined(separator: "\n"))))
        }
        return cards.filter { !$0.question.isEmpty }
    }

    /// Words that head answers, in the languages notes are written in. A heading that also names questions
    /// ("Kısa cevaplı sorular", short-answer questions) heads questions, unless it says answers outright.
    private static let answerWords = ["cevap", "yanit", "cozum", "answer", "solution", "antwort", "losung",
                                      "reponse", "corrige", "respuesta", "solucion", "risposta", "soluzion",
                                      "ответ", "решени", "إجاب", "حلول"]
    private static let surelyAnswers = ["anahtar", "cevaplar", "yanitlar", "cozumler", "beklenen", "answers", "answer key",
                                        "solutions", "expected", "antworten", "losungen", "reponses", "respuestas", "risposte"]
    private static let questionWords = ["soru", "question", "frage", "pregunta", "domand", "вопрос", "سؤال"]

    static func namesAnswers(_ heading: String) -> Bool {
        let folded = LibrarySearch.fold(heading)
        if surelyAnswers.contains(where: folded.contains) { return true }
        if questionWords.contains(where: folded.contains) { return false }
        return answerWords.contains(where: folded.contains)
    }

    private static let start = try? NSRegularExpression(pattern: #"^ {0,3}(#{1,6} *)?(?:\*\*)?(\d{1,3})[.)](?:\*\*)?[ \t]+(.*)$"#)

    private static func numbered(_ line: String) -> (number: Int, heading: Bool, text: String)? {
        guard let start, let match = start.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let numberRange = Range(match.range(at: 2), in: line), let number = Int(line[numberRange]),
              let textRange = Range(match.range(at: 3), in: line) else { return nil }
        return (number, match.range(at: 1).location != NSNotFound, String(line[textRange]).trimmingCharacters(in: .whitespaces))
    }

    private static func tidy(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func join(_ a: String, _ b: String) -> String {
        [a, b].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// What the student knew last time for each card of a course, in the course folder's `.lectern/practice.json`.
public struct PracticeLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var known: Bool
        public var at: Date
    }

    public var entries: [String: Entry] = [:]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public mutating func record(_ id: String, known: Bool, at date: Date = Date()) {
        entries[id] = Entry(known: known, at: date)
    }

    /// Missed ones first, then new ones, then known ones from the longest ago; `random` breaks ties.
    public func order(_ cards: [PracticeCard], random: (Int) -> Int = { Int.random(in: 0..<max(1, $0)) }) -> [PracticeCard] {
        let keyed = cards.map { card -> (PracticeCard, Int, Date, Int) in
            let entry = entries[card.id]
            let rank = entry.map { $0.known ? 2 : 0 } ?? 1
            return (card, rank, entry?.at ?? .distantPast, random(1_000_000))
        }
        return keyed.sorted { ($0.1, $0.2, $0.3) < ($1.1, $1.2, $1.3) }.map(\.0)
    }
}

extension Library {
    func practiceURL(ofCourse id: String) -> URL {
        folder(ofCourse: id).appendingPathComponent(".lectern/practice.json")
    }

    public func practiceLog(ofCourse id: String) -> PracticeLog {
        (try? JSONStore.read(PracticeLog.self, from: practiceURL(ofCourse: id))) ?? PracticeLog()
    }

    public func save(_ log: PracticeLog, ofCourse id: String) throws {
        try JSONStore.write(log, to: practiceURL(ofCourse: id))
    }
}
