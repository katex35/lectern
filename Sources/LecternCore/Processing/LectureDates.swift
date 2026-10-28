import Foundation

/// Finds the dates a lecturer gives (exams, deadlines, a moved class) in a transcript.
enum LectureDates {
    static func prompt(language: String) -> String {
        """
        You read the transcript of one recorded lecture and list every date the lecturer gives for an exam, \
        a quiz, an assignment or project deadline, a presentation, or a class that is cancelled or moved.

        Answer with JSON only, no other text:
        {"dates": [{"kind": "exam" | "assignment" | "other", "title": "...", "date": "YYYY-MM-DD", \
        "time": "HH:MM" or null, "quote": "...", "at": "HH:MM:SS"}]}

        - "title": a few words in \(NotePrompts.languageName(language)), such as the exam's or assignment's name.
        - "date": work out relative dates ("next Wednesday", "in two weeks") from the lecture's date given above \
        the transcript. Leave out a date whose day cannot be worked out, and dates before the lecture.
        - "quote": the lecturer's own words that give the date, copied from the transcript, at most 25 words.
        - "at": the [HH:MM:SS] time of the transcript piece the quote is in.
        - Each date once. An empty list when the lecturer gives none.
        """
    }

    private struct Answer: Decodable {
        struct Item: Decodable {
            var kind: String?
            var title: String?
            var date: String?
            var time: String?
            var quote: String?
            var at: String?
        }

        var dates: [Item]
    }

    /// The model's answer as dates, tolerating a fenced or prefixed reply. Dates before the lecture's day
    /// and repeats of one kind on one day are left out.
    static func parse(_ text: String, lectureDate: Date, transcript: String, calendar: Calendar = .current) -> [MentionedDate] {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(text[open...close].utf8)) else { return [] }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let lectureDay = calendar.startOfDay(for: lectureDate)
        var found: [MentionedDate] = []
        for item in answer.dates {
            guard let text = item.date, let start = day.date(from: text), start >= lectureDay else { continue }
            let clock = item.time.flatMap(ClockTime.init) ?? ClockTime(hour: 9, minute: 0)
            guard let date = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: start) else { continue }
            let kind = item.kind.flatMap(CourseDate.Kind.init(rawValue:)) ?? .other
            if found.contains(where: { $0.kind == kind && calendar.isDate($0.date, inSameDayAs: date) }) { continue }
            let quote = (item.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(MentionedDate(kind: kind, title: title, date: date, quote: quote,
                                       at: locate(quote, in: transcript) ?? item.at.flatMap(seconds)))
        }
        return found.sorted { $0.date < $1.date }
    }

    /// "01:31:40" as seconds.
    static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    /// Where in the lecture the quote was said: the start of its transcript piece, moved on by how far
    /// into the piece it stands. Nil when the quote is not in the transcript.
    static func locate(_ quote: String, in transcript: String) -> TimeInterval? {
        let words = LibrarySearch.fold(quote).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(6)
        guard words.count >= 3 else { return nil }
        var pieces: [(start: TimeInterval, text: String)] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), let start = seconds(String(trimmed.dropFirst().dropLast())) {
                pieces.append((start, ""))
            } else if !pieces.isEmpty {
                pieces[pieces.count - 1].text += line + "\n"
            }
        }
        for (index, piece) in pieces.enumerated() {
            // the piece's words in a row, so line breaks and punctuation do not hide the quote
            let text = LibrarySearch.fold(piece.text).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            guard text.count >= words.count else { continue }
            for position in 0...(text.count - words.count) where text[position..<(position + words.count)].elementsEqual(words) {
                let end = index + 1 < pieces.count ? pieces[index + 1].start : piece.start + 300
                return (piece.start + (end - piece.start) * Double(position) / Double(text.count)).rounded()
            }
        }
        return nil
    }

    /// Dates found again keep the choice made about them; ones already chosen stay even when the new
    /// answer misses them, ones never looked at go.
    static func merge(_ found: [MentionedDate], keeping old: [MentionedDate], calendar: Calendar = .current) -> [MentionedDate] {
        var merged: [MentionedDate] = []
        var used: Set<UUID> = []
        for var date in found {
            if let match = old.first(where: { !used.contains($0.id) && $0.kind == date.kind && calendar.isDate($0.date, inSameDayAs: date.date) }) {
                date.id = match.id
                date.decision = match.decision
                used.insert(match.id)
            }
            merged.append(date)
        }
        merged += old.filter { !used.contains($0.id) && $0.decision != .pending }
        return merged.sorted { $0.date < $1.date }
    }
}
