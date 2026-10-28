import Foundation

/// One block of a notes file. Text in headings, paragraphs, list items and cells is inline Markdown
/// with its formulas already turned into plain text.
public enum NoteBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    case numbered(number: Int, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    /// A displayed formula as plain text, possibly several lines.
    case formula(String)
    case rule
}

/// Splits generated notes into blocks: the Markdown subset the notes use, with LaTeX formulas.
public enum NoteDocument {
    /// The heading the notes open with, without a generic lead such as "Ders Notu:"; nil when there is none
    /// or nothing specific is left. It is the heading `parse(_:dropsTitle:)` leaves out.
    public static func title(of source: String) -> String? {
        let first = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line = first, line.hasPrefix("#") else { return nil }
        var text = line.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
        for lead in genericLeads {
            guard text.lowercased().hasPrefix(lead) else { continue }
            let rest = text.dropFirst(lead.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return nil }
            if let separator = rest.first, ":-".contains(separator) {
                text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                break
            }
        }
        text = replacingFormulas(in: text, escaped: false)
        return text.isEmpty ? nil : text
    }

    private static let genericLeads = ["ders notları", "ders notu", "lecture notes", "lecture note", "notlar", "notes"]

    /// - Parameter dropsTitle: leaves out the leading heading, because the page shows it as its title.
    public static func parse(_ source: String, dropsTitle: Bool = false) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var previousBlank = true
        var atStart = true

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { previousBlank = true; continue }
            let isFirstLine = atStart
            defer { previousBlank = false; atStart = false }

            // displayed formula: \[ ... \] or $$ ... $$, on one line or several;
            // one that is never closed stays ordinary text instead of swallowing the rest of the notes
            if let opener = ["\\[", "$$"].first(where: { line.hasPrefix($0) }) {
                let closer = opener == "\\[" ? "\\]" : "$$"
                var body = String(line.dropFirst(opener.count))
                var closed = false
                if let end = body.range(of: closer) {
                    body = String(body[..<end.lowerBound])
                    closed = true
                } else if let last = lines[i...].firstIndex(where: { $0.contains(closer) }),
                          let end = lines[last].range(of: closer) {
                    for next in lines[i..<last] { body += "\n" + next }
                    body += "\n" + lines[last][..<end.lowerBound]
                    i = last + 1
                    closed = true
                }
                if closed {
                    let formula = MathText.plain(body)
                    if !formula.isEmpty { blocks.append(.formula(formula)) }
                    continue
                }
            }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if !(dropsTitle && isFirstLine) { blocks.append(.heading(level: level, text: inline(text))) }
                continue
            }

            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), line.count >= 3 {
                blocks.append(.rule)
                continue
            }

            if line.hasPrefix("|") {
                var tableLines = [line]
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    tableLines.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                let rows = tableLines
                    .filter { !isSeparatorRow($0) }
                    .map(cells)
                if let header = rows.first { blocks.append(.table(header: header, rows: Array(rows.dropFirst()))) }
                continue
            }

            if line.hasPrefix(">") {
                blocks.append(.quote(inline(line.drop(while: { $0 == ">" || $0 == " " }).description)))
                continue
            }

            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                blocks.append(.bullet(depth: indent / 2, text: inline(String(line.dropFirst(2)))))
                continue
            }
            if let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]),
               line[line.index(after: dot)...].first == " " {
                blocks.append(.numbered(number: number, text: inline(String(line[line.index(dot, offsetBy: 2)...]))))
                continue
            }

            // an indented line under a list item belongs to it
            if indent >= 2, !previousBlank, let last = blocks.last {
                switch last {
                case .bullet(let depth, let text):
                    blocks[blocks.count - 1] = .bullet(depth: depth, text: text + "\n" + inline(line))
                    continue
                case .numbered(let number, let text):
                    blocks[blocks.count - 1] = .numbered(number: number, text: text + "\n" + inline(line))
                    continue
                default:
                    break
                }
            }

            if !previousBlank, case .paragraph(let text)? = blocks.last {
                // Markdown joins wrapped lines; two trailing spaces keep the break
                let separator = lines[i - 2].hasSuffix("  ") ? "\n" : " "
                blocks[blocks.count - 1] = .paragraph(text + separator + inline(line))
                continue
            }
            blocks.append(.paragraph(inline(line)))
        }
        return blocks
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        line.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return splitCells(String(body)).map { inline($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Splits on `|` outside inline formulas, so `\(|x|\)` stays in one cell.
    private static func splitCells(_ text: String) -> [String] {
        var cells: [String] = [], current = "", inFormula = false
        var iterator = text.makeIterator()
        while let c = iterator.next() {
            if c == "\\", let next = iterator.next() {
                if next == "(" { inFormula = true } else if next == ")" { inFormula = false }
                current.append(c)
                current.append(next)
                continue
            }
            if c == "|", !inFormula {
                cells.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        cells.append(current)
        return cells
    }

    /// Inline formulas `\( ... \)` become escaped plain text inside the Markdown.
    static func inline(_ text: String) -> String {
        replacingFormulas(in: text, escaped: true)
    }

    private static func replacingFormulas(in text: String, escaped escapes: Bool) -> String {
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "\\(") {
            out += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.range(of: "\\)") else {
                rest = rest[start.lowerBound...]
                break
            }
            let formula = MathText.plain(String(after[..<end.lowerBound]))
            out += escapes ? escaped(formula) : formula
            rest = after[end.upperBound...]
        }
        out += rest
        return out
    }

    /// Keeps characters that Markdown would read as emphasis or links literal.
    private static func escaped(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\*_`[]<>#".contains(c) { out.append("\\") }
            out.append(c == "\n" ? " " : c)
        }
        return out
    }
}
