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
        ZStack {
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
}
