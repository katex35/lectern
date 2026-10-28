import Foundation

/// A place where the search words were found.
public struct SearchHit: Equatable, Sendable, Identifiable {
    public enum Source: String, Sendable {
        case notes, transcript, chat
    }

    public var id: String { "\(session.courseID ?? "")/\(session.id)/\(source.rawValue)/\(offset)" }
    public var session: Session
    public var source: Source
    /// The line around the match, shortened.
    public var snippet: String
    /// For a transcript, the moment of the piece the match is in.
    public var time: TimeInterval?
    /// Where in the file, to keep hits in reading order.
    public var offset: Int
}

/// Looks through the notes, transcripts and conversations of every session. Case and accents do not
/// matter, so "ozet" finds "Özet" and "I" finds "ı".
public enum LibrarySearch {
    public static func search(_ query: String, in sessions: [Session], library: Library, limit: Int = 60) -> [SearchHit] {
        let words = fold(query).split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for session in sessions {
            let folder = library.folder(of: session)
            let sources: [(SearchHit.Source, String?)] = [
                (.notes, try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)),
                (.transcript, try? String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)),
                (.chat, LectureChat.load(from: folder).map(\.text).joined(separator: "\n")),
            ]
            for (source, text) in sources {
                guard let text, !text.isEmpty else { continue }
                hits += find(words, in: text, source: source, session: session)
                if hits.count >= limit { return Array(hits.prefix(limit)) }
            }
        }
        return hits
    }

    /// Lines holding every word; in a transcript the last [HH:MM:SS] before the line gives the time.
    static func find(_ words: [String], in text: String, source: SearchHit.Source, session: Session) -> [SearchHit] {
        var hits: [SearchHit] = []
        var stamp: TimeInterval?
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { offset += line.count + 1 }
            if source == .transcript, let time = stampTime(line) {
                stamp = time
                continue
            }
            let folded = fold(String(line))
            guard words.allSatisfy({ folded.contains($0) }) else { continue }
            hits.append(SearchHit(session: session, source: source, snippet: snippet(String(line), around: words[0]),
                                  time: source == .transcript ? stamp : nil, offset: offset))
            // a few per file, so one long lecture does not fill the list
            if hits.count >= 5 { break }
        }
        return hits
    }

    /// "[01:02:03]" as seconds.
    static func stampTime<S: StringProtocol>(_ line: S) -> TimeInterval? {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        let parts = line.dropFirst().dropLast().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    /// Lower case without accents; the Turkish dotless and dotted i both become "i".
    public static func fold(_ text: String) -> String {
        dotless(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// ı and İ as i, one letter for one, so positions stay those of the original text.
    static func dotless(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i")
    }

    /// Where the words of `query` stand in `text`, ignoring case and accents. Found in the text itself,
    /// so letters that fold into two (ß) do not shift them.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let prepared = dotless(text)
        var found: [Range<String.Index>] = []
        for word in dotless(query).split(separator: " ") where word.count >= 2 {
            var from = prepared.startIndex
            while let match = prepared.range(of: word, options: [.caseInsensitive, .diacriticInsensitive],
                                             range: from..<prepared.endIndex) {
                let start = prepared.distance(from: prepared.startIndex, to: match.lowerBound)
                let length = prepared.distance(from: match.lowerBound, to: match.upperBound)
                let lower = text.index(text.startIndex, offsetBy: start)
                found.append(lower..<text.index(lower, offsetBy: length))
                from = match.upperBound
            }
        }
        return found
    }

    /// The line cut to about 140 characters around the first word, without Markdown marks.
    static func snippet(_ line: String, around word: String) -> String {
        let clean = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\\(", with: "")
            .replacingOccurrences(of: "\\)", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#-*> ").union(.whitespaces))
        guard clean.count > 140 else { return clean }
        let at = ranges(of: word, in: clean).first.map { clean.distance(from: clean.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(at - 50, clean.count - 140))
        var begin = clean.index(clean.startIndex, offsetBy: start)
        var end = clean.index(begin, offsetBy: min(140, clean.distance(from: begin, to: clean.endIndex)))
        // whole words at both ends
        if start > 0, let space = clean[begin...].firstIndex(of: " "), clean.distance(from: begin, to: space) < 20 {
            begin = clean.index(after: space)
        }
        if end < clean.endIndex, let space = clean[..<end].lastIndex(of: " "), clean.distance(from: space, to: end) < 20 {
            end = space
        }
        return (start > 0 ? "…" : "") + clean[begin..<end] + (end < clean.endIndex ? "…" : "")
    }
}
