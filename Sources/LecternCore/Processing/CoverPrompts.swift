import Foundation

/// Covers for courses and lectures, made from their topic and never showing anything unsuitable:
/// a text model first turns the topic into one plain visual idea, which is checked, then a fixed style
/// with its own exclusions is added before it goes to the image model.
public enum CoverPrompts {
    /// What the text model is told when it turns a topic into a picture idea.
    public static let subjectSystem = """
    You turn the topic of a university course or lecture into one idea for a small cover picture. Answer with one \
    sentence in English that describes simple objects and abstract shapes only: no people, faces, hands, bodies, \
    animals, text, letters, numbers, logos, brands, flags, religious or political symbols, weapons, injuries or \
    anything scary. A visual metaphor for the topic, friendly and calm. Only the sentence, nothing else.
    """

    static let style = """
    Square 1:1 composition. Soft modern editorial illustration with a subtle matte paper grain, simple rounded \
    geometric shapes, gentle depth from flat layered planes, calm and friendly. Limited palette: %@ with warm \
    off-white and soft greys. Centered subject with generous breathing room, readable as a tiny thumbnail. \
    Strictly no people, no faces, no hands, no animals, no text, no letters, no numbers, no logos, no trademarks, \
    no watermark, no border, no frame. Nothing violent, scary, sexual, political or religious. \
    Original design only. Intended use: cover image for a course in a note-taking app.
    """

    /// Words that send a suggested idea back to the plain abstract one.
    static let refused = ["person", "people", "man", "woman", "men", "women", "child", "boy", "girl", "face", "hand",
                          "body", "human", "student", "teacher", "professor", "crowd", "animal", "dog", "cat", "bird",
                          "text", "letter", "word", "number", "logo", "brand", "flag", "cross", "crescent", "star of",
                          "religio", "politic", "weapon", "gun", "knife", "blood", "skull", "death", "war", "nude", "sex"]

    /// The text model's request for a course or a lecture topic.
    public static func subjectRequest(model: String, topic: String, course: String?) -> CompletionRequest {
        var lines = ["Topic: \(topic)"]
        if let course, course != topic { lines.append("Course: \(course)") }
        return CompletionRequest(model: model, system: subjectSystem, messages: [ChatMessage(.user, lines.joined(separator: "\n"))],
                                 maxOutputTokens: 200)
    }

    /// The idea a text model suggested, if it passes; otherwise a calm abstract one.
    public static func subject(_ suggestion: String?) -> String {
        let fallback = "soft overlapping rounded shapes and a few small floating dots, like pages and ideas gently stacking"
        guard let suggestion else { return fallback }
        let line = suggestion.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.")) ?? ""
        let lowered = " \(line.lowercased()) "
        let unsafe = refused.contains { word in
            // whole words for short ones, so "manifold" or "hands-on" do not trip "man" or "hand"
            word.count <= 5 ? lowered.range(of: "\\b\(word)s?\\b", options: .regularExpression) != nil : lowered.contains(word)
        }
        guard !line.isEmpty, line.count <= 400, !unsafe else { return fallback }
        return line
    }

    /// The full prompt for the image model; `color` is the course's own, like "#3B82F6".
    public static func image(subject: String, color: String?) -> String {
        let palette = color.map { "\($0) and lighter tints of it" } ?? "soft blue and slate grey"
        let start = subject.prefix(1).uppercased() + subject.dropFirst()
        return "\(start). " + String(format: style, palette)
    }
}
