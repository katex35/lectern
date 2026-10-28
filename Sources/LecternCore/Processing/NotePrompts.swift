import Foundation

/// What the note-writing model is told. Kept in English for the model; the output language is named.
enum NotePrompts {
    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    static func notes(language: String) -> String {
        """
        You write study notes for a student from the transcript of a recorded lecture. Write them in \(languageName(language)), \
        whatever language the lecture was given in; keep technical terms in the lecture's language in parentheses where that helps.

        Format, in Markdown:
        - Start with one line "# " and the lecture's actual topic. No generic title such as "Lecture notes".
        - Then "## " sections in the order the lecture went, "### " for parts of a section.
        - Short paragraphs and bullet lists. Put each defined term in bold where it is defined.
        - Formulas in LaTeX: \\( ... \\) inside a sentence, \\[ ... \\] on lines of their own.
        - A table when the lecture compares things or works through values.
        - If the lecturer said something matters for the exam, or the student marked a moment, collect those points \
        in a last section with a heading in \(languageName(language)) that says so.
        - If the student photographed the board, put each listed photo exactly once, on a line of its own as \
        ![](board/FILE), in the section about what was being explained at the photo's time. You cannot see the \
        photos, so do not describe what is on them.

        Use only what is in the transcript and the student's notes. Where the transcript is garbled or a formula \
        cannot be made out, say so in one short sentence instead of guessing. The transcript is split into pieces \
        with [HH:MM:SS] times; do not copy those times into the notes. No preface, no closing remarks.
        """
    }

    static func questions(language: String) -> String {
        """
        You write practice questions for a student from their notes on one lecture, in \(languageName(language)).

        Format, in Markdown:
        - Start with one line "# " naming the lecture's topic.
        - Then 8 to 12 numbered questions, from definitions to understanding, and a worked problem wherever \
        the lecture had calculations.
        - Under each question, its answer as a quote ("> "), short and complete.
        - Formulas in LaTeX: \\( ... \\) inside a sentence, \\[ ... \\] on lines of their own.

        Ask only about what the notes cover. No preface, no closing remarks.
        """
    }

    /// The lecture as the model sees it: what it is, the student's own notes with their times, the transcript.
    static func lecture(session: Session, course: Course?, transcript: String) -> String {
        var parts: [String] = []
        var about = [course.map { "Course: \($0.name)" } ?? "Meeting: \(session.title)"]
        if let week = session.week { about.append("Week: \(week)") }
        // the local day with its name, so "next Wednesday" can be worked out from it
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd, EEEE"
        about.append("Date: \(day.string(from: session.date))")
        parts.append(about.joined(separator: "\n"))

        let offsets = timelineOffsets(session)
        let marks = session.markers.sorted { ($0.created) < ($1.created) }.map { marker -> String in
            let time = (offsets[marker.recording] ?? 0) + marker.time
            return "[\(SessionProcessor.stamp(time))] \(marker.text)"
        }
        if !marks.isEmpty {
            parts.append("The student's notes during the lecture:\n" + marks.joined(separator: "\n"))
        }
        let photos = session.photos.compactMap { photo -> (TimeInterval, String)? in
            guard let recording = photo.recording, let time = photo.time else { return nil }
            return ((offsets[recording] ?? 0) + time, photo.file)
        }.sorted { $0.0 < $1.0 }
        if !photos.isEmpty {
            parts.append("Board photos the student took:\n" + photos.map { "[\(SessionProcessor.stamp($0.0))] board/\($0.1)" }
                .joined(separator: "\n"))
        }
        parts.append("Transcript:\n" + transcript)
        return parts.joined(separator: "\n\n")
    }

    /// Where each recording starts when the session's recordings are played back to back.
    static func timelineOffsets(_ session: Session) -> [String: TimeInterval] {
        var offsets: [String: TimeInterval] = [:]
        var cursor: TimeInterval = 0
        for recording in session.orderedRecordings {
            offsets[recording.file] = cursor
            cursor += recording.duration ?? 0
        }
        return offsets
    }
}
