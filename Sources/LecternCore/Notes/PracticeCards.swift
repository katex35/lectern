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
    /// "#### 9. Expected answer" sections further down. A number seen again later holds the answer.
    public static func parse(_ source: String, prefix: String) -> [PracticeCard] {
        struct Block {
            var number: Int
            var heading: Bool
            var first: String
            var lines: [String] = []
        }
        var blocks: [Block] = []
        var current: Block?
        let close = {
            if let block = current { blocks.append(block) }
            current = nil
        }
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let start = numbered(raw) {
                // list items inside a heading's block are its steps, not new questions
                if start.heading || current?.heading != true {
                    close()
                    current = Block(number: start.number, heading: start.heading, first: start.text)
                    continue
                }
            } else if line.hasPrefix("#") {
                close()
                continue
            }
            current?.lines.append(raw)
        }
        close()

        var cards: [PracticeCard] = []
        var index: [Int: Int] = [:]
        for block in blocks {
            let body = block.lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            let quoted = block.lines.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(">") else { return nil }
                return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let at = index[block.number] {
                // seen before: this is its answer; a heading such as "Expected answer" says nothing itself
                let text = (block.heading ? body : [block.first] + body).joined(separator: "\n")
                cards[at].answer = join(cards[at].answer, tidy(text))
            } else {
                index[block.number] = cards.count
                let title = block.heading ? "**\(block.first)**" : block.first
                cards.append(PracticeCard(id: "\(prefix)#\(block.number)", number: block.number,
                                          question: tidy(([title] + body).joined(separator: "\n")),
                                          answer: tidy(quoted.joined(separator: "\n"))))
            }
        }
        return cards.filter { !$0.question.isEmpty }
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
