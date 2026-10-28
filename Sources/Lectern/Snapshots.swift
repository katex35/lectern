import AppKit
import LecternCore
import SwiftUI

/// Development check: with `LECTERN_SNAPSHOT=<folder>` the app saves each main screen as a PNG and quits.
/// Recording uses the simulated microphone when `LECTERN_SIMULATE` is set as well.
@MainActor
enum Snapshots {
    static func runIfRequested(_ model: AppModel) async {
        guard let path = ProcessInfo.processInfo.environment["LECTERN_SNAPSHOT"], !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await pause(1.0)
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        await pause(1.6)
        save(window, to: folder.appendingPathComponent("1-home.png"))

        if let session = model.sessions.first(where: { model.text("notes.md", in: $0) != nil }) ?? model.sessions.first {
            model.open(session)
            await pause(4)
            save(window, to: folder.appendingPathComponent("2-session.png"))
            if let notes = model.text("notes.md", in: session) {
                // the whole notes, to check tables and formulas further down
                let renderer = ImageRenderer(content: MarkdownText(source: notes, title: SessionText.title(session, model: model))
                    .frame(width: 712).padding(24).background(.white).environment(\.colorScheme, .light))
                renderer.scale = 1
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("2b-notes.png"))
                }
            }
        }

        if ProcessInfo.processInfo.environment["LECTERN_SIMULATE"] != nil {
            model.record(model.courses.first)
            await pause(4)
            model.recorder.addNote("Sınavda çıkabilir dedi")
            await pause(1.2)
            save(window, to: folder.appendingPathComponent("3-recording.png"))
            await model.recorder.stop()
            await pause(2)
            save(window, to: folder.appendingPathComponent("4-after.png"))
        }

        model.sidebarVisible = false
        model.goHome()
        await pause(1.2)
        save(window, to: folder.appendingPathComponent("5-no-sidebar.png"))
        NSApp.terminate(nil)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
