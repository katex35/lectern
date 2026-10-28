import AppKit
import LecternCore
import SwiftUI

/// A course's or a session's picture: the image generated for it when there is one, otherwise a calm
/// shape in the course color while it is being made. Never a stock icon.
struct CoverView: View {
    @Environment(AppModel.self) private var model
    var course: Course?
    var session: Session?
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat

    var body: some View {
        let color = Theme.color(of: course, among: model.courses)
        // a cover drawn later is a new file; the revision tells this view to look again
        _ = model.revision
        return ZStack {
            if let image = Covers.image(course: course, session: session, library: model.library) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                color.opacity(0.16)
                Canvas { context, size in
                    let d = max(size.width, size.height)
                    context.fill(Path(ellipseIn: CGRect(x: -d * 0.02, y: size.height * 0.28, width: d * 0.68, height: d * 0.68)),
                                 with: .color(color.opacity(0.35)))
                    context.fill(Path(ellipseIn: CGRect(x: size.width * 0.44, y: size.height * 0.14, width: d * 0.52, height: d * 0.52)),
                                 with: .color(color.opacity(0.6)))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Covers live in the library: `Covers/<course id>.jpg`, or `cover.jpg` in a session folder.
@MainActor
enum Covers {
    private static var cache: [URL: NSImage] = [:]

    static func image(course: Course?, session: Session?, library: Library) -> NSImage? {
        var candidates: [URL] = []
        if let session { candidates.append(library.folder(of: session).appendingPathComponent("cover.jpg")) }
        if let id = course?.id ?? session?.courseID {
            candidates.append(library.root.appendingPathComponent("Covers/\(id).jpg"))
        } else if session?.kind == .meeting {
            candidates.append(library.root.appendingPathComponent("Covers/meetings.jpg"))
        }
        for url in candidates {
            if let cached = cache[url] { return cached }
            if let image = NSImage(contentsOf: url) {
                cache[url] = image
                return image
            }
        }
        return nil
    }

    // MARK: drawing

    /// What draws covers: an OpenAI or a Gemini key. The ChatGPT sign-in cannot make images.
    static func maker() -> (any ImageMaker)? {
        if ProcessInfo.processInfo.environment["LECTERN_FAKE_AI"] != nil { return Snapshots.FakeImageMaker() }
        if let key = (try? Providers.credentials.apiKey(for: .openAI)) ?? nil { return OpenAIImageMaker(apiKey: key) }
        if let key = (try? Providers.credentials.apiKey(for: .gemini)) ?? nil { return GeminiImageMaker(apiKey: key) }
        return nil
    }

    private static var drawing: Set<URL> = []

    /// A cover for a course from its name, unless it has one.
    static func draw(for course: Course, model: AppModel, replacing: Bool = false) async {
        await draw(topic: course.name, course: course,
                   into: model.library.root.appendingPathComponent("Covers/\(course.id).jpg"), replacing: replacing, model: model)
    }

    /// A cover for a lecture from the topic of its notes, unless it has one.
    static func draw(for session: Session, model: AppModel) async {
        guard let notes = model.text("notes.md", in: session), let topic = NoteDocument.title(of: notes) else { return }
        await draw(topic: topic, course: model.course(session.courseID),
                   into: model.folder(of: session).appendingPathComponent("cover.jpg"), replacing: false, model: model)
    }

    /// The text model first turns the topic into a plain picture idea, which is checked before the
    /// fixed style with its exclusions is added; see `CoverPrompts`.
    private static func draw(topic: String, course: Course?, into url: URL, replacing: Bool, model: AppModel) async {
        guard replacing || !FileManager.default.fileExists(atPath: url.path), !drawing.contains(url), let maker = maker() else { return }
        drawing.insert(url)
        defer { drawing.remove(url) }
        var idea: String?
        if let writer = (try? await Providers.writer()) ?? nil {
            let request = CoverPrompts.subjectRequest(model: writer.model, topic: topic, course: course?.name)
            idea = try? await writer.provider.complete(request).text
        }
        let color = course?.colorHex ?? course.flatMap { model.courses.firstIndex(of: $0) }.map { Theme.paletteHex[$0 % Theme.paletteHex.count] }
        do {
            let data = try await maker.image(prompt: CoverPrompts.image(subject: CoverPrompts.subject(idea), color: color))
            try CoverImage.write(data, to: url)
            cache[url] = nil
            model.reload()
        } catch {
            model.show(L("covers.failed"))
        }
    }
}
