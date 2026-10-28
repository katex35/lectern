import AppKit
import LecternCore
import SwiftUI

/// Development check: with `LECTERN_SNAPSHOT=<folder>` the app saves each main screen as a PNG and quits.
/// Recording uses the simulated microphone when `LECTERN_SIMULATE` is set as well.
@MainActor
enum Snapshots {
    static func runIfRequested(_ model: AppModel) async {
        if let path = ProcessInfo.processInfo.environment["LECTERN_ICON"], !path.isEmpty {
            saveIcon(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
            return
        }
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
                let renderer = ImageRenderer(content: MarkdownText(source: notes, dropsTitle: true)
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
            // a break with Stop pressed while the first half is still closing ends the lecture
            async let pausing: Void = model.recorder.takeBreak()
            await model.recorder.stop()
            await pausing
            await pause(1)
            save(window, to: folder.appendingPathComponent("3b-stop-during-break.png"))
            // a real break, then the second half joins the same session
            model.record(model.courses.first)
            await pause(3)
            await model.recorder.takeBreak()
            await pause(1)
            save(window, to: folder.appendingPathComponent("3c-break.png"))
            await model.recorder.resume()
            await pause(3)
            await model.recorder.stop()
            await pause(0.8)
            save(window, to: folder.appendingPathComponent("4-after.png"))
            // with LECTERN_FAKE_AI the transcript and notes follow on their own
            if let session = model.recorder.session {
                for _ in 0..<40 where model.processing.isRunning(session) { await pause(0.5) }
                await pause(1)
                save(window, to: folder.appendingPathComponent("4b-processed.png"))
            }
        }

        model.sidebarVisible = false
        model.goHome()
        await pause(1.2)
        save(window, to: folder.appendingPathComponent("5-no-sidebar.png"))
        NSApp.terminate(nil)
    }

    /// Answers every piece after a moment, so the progress can be seen.
    struct FakeTranscriber: Transcribing {
        func transcribe(_ audio: URL, languages: [String], vocabulary: [String]) async throws -> String {
            try await Task.sleep(nanoseconds: 1_200_000_000)
            return "Bugün zincir kuralını ve geri yayılımı konuşacağız. Bu kısım sınavda çıkar."
        }
    }

    /// Writes short fixed notes and questions.
    struct FakeWriter: LanguageModelProvider {
        let kind = ProviderKind.anthropic

        func models() async throws -> [ModelInfo] { [] }

        func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
            let text = request.system.contains("practice questions")
                ? "# Zincir kuralı\n\n1. Zincir kuralı neyi hesaplar?\n> İç değişkenlere göre türevleri çarparak sonucun türevini.\n"
                : "# Zincir kuralı ve geri yayılım\n\n## Zincir kuralı\n\n- **Zincir kuralı:** \\(\\frac{\\partial C}{\\partial w} = \\frac{\\partial C}{\\partial a}\\cdot\\frac{\\partial a}{\\partial w}\\)\n\n## Sınavda çıkabilecekler\n\n- Hoca zincir kuralının sınavda çıkacağını söyledi.\n"
            return AsyncThrowingStream { continuation in
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continuation.yield(.text(text))
                    continuation.yield(.finished(CompletionResult(stop: .complete)))
                    continuation.finish()
                }
            }
        }
    }

    /// The app icon at 1024 points for `scripts/bundle.sh`: the logo on a white tile, inside the margin
    /// macOS icons keep around their shape.
    private static func saveIcon(to url: URL) {
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
                .frame(width: 824, height: 824)
            LogoMark(size: 520)
        }
        .frame(width: 1024, height: 1024)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
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
