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
    /// - Parameter title: dropped when it is the first heading, because the page already shows it.
    public static func parse(_ source: String, droppingTitle title: String? = nil) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var previousBlank = true

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { previousBlank = true; continue }
            defer { previousBlank = false }

            // displayed formula: \[ ... \] or $$ ... $$, on one line or several
            if let opener = ["\\[", "$$"].first(where: { line.hasPrefix($0) }) {
                let closer = opener == "\\[" ? "\\]" : "$$"
                var body = String(line.dropFirst(opener.count))
                if let end = body.range(of: closer) {
                    body = String(body[..<end.lowerBound])
                } else {
                    while i < lines.count {
                        let next = lines[i]
                        i += 1
                        if let end = next.range(of: closer) {
                            body += "\n" + next[..<end.lowerBound]
                            break
                        }
                        body += "\n" + next
                    }
                }
                let formula = MathText.plain(body)
                if !formula.isEmpty { blocks.append(.formula(formula)) }
                continue
            }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                let isTitle = blocks.isEmpty && title.map { $0.trimmingCharacters(in: .whitespaces) == text } == true
                if !isTitle { blocks.append(.heading(level: level, text: inline(text))) }
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
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "\\(") {
            out += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.range(of: "\\)") else {
                rest = rest[start.lowerBound...]
                break
            }
            out += escaped(MathText.plain(String(after[..<end.lowerBound])))
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
