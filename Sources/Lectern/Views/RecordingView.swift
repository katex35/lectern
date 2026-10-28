import AppKit
import LecternCore
import SwiftUI

struct RecordingView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        let recorder = model.recorder
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                StatusLine()
                switch recorder.phase {
                case .onBreak:
                    BreakPanel()
                case .failed(let message):
                    FailurePanel(message: message)
                default:
                    LiveClock()
                    LiveWave(levels: recorder.levels, running: recorder.phase == .recording)
                        .frame(height: 48)
                    Controls()
                }
            }
            .padding(.top, 24)
            .frame(maxWidth: 760)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .trailing, spacing: 8) {
                        ForEach(recorder.notes) { note in
                            HStack(spacing: 8) {
                                Text(note.time.clock)
                                    .font(.system(size: 11.5).monospacedDigit())
                                    .foregroundStyle(Theme.tertiary)
                                Text(note.text)
                                    .font(.system(size: 14))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color(hex: 0xF4F4F4)))
                            .id(note.id)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .frame(maxWidth: 712, alignment: .trailing)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .onChange(of: recorder.notes.count) {
                    if let last = recorder.notes.last { withAnimation(Theme.ease) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            Composer(draft: $draft, focused: $composerFocused) { model.recorder.addNote(draft); draft = "" }
                .disabled(recorder.phase != .recording)
                .opacity(recorder.phase == .recording ? 1 : 0.5)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity)
        .onAppear { composerFocused = true }
    }
}

private struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recorder = model.recorder
        let live = recorder.phase == .recording
        HStack(spacing: 7) {
            PulsingDot(active: live, color: live ? Theme.record : Color(hex: 0x8E8E8E))
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
    }

    private var label: String {
        let recorder = model.recorder
        switch recorder.phase {
        case .starting: return L("recording.starting")
        case .onBreak: return L("recording.break")
        case .stopping: return L("recording.saving")
        case .failed: return L("recording.failed")
        default:
            if let course = recorder.course {
                return recorder.session?.week.map { "\(course.shortName) · \(L("session.week", $0))" } ?? course.shortName
            }
            return L("session.meeting")
        }
    }
}

private struct LiveClock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(model.recorder.elapsed(at: context.date).clock)
                .font(.system(size: 52, weight: .medium).monospacedDigit())
                .kerning(-2)
                .contentTransition(.numericText())
                .animation(Theme.quick, value: Int(model.recorder.elapsed(at: context.date)))
        }
        .accessibilityLabel(L("recording.elapsed"))
    }
}

/// Bars from the microphone level; the newest ones on the right are red.
struct LiveWave: View {
    let levels: [CGFloat]
    var running: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(color(index))
                    .frame(width: 3.5, height: max(5, 48 * (running ? level : 0.1)))
            }
        }
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }

    private func color(_ index: Int) -> Color {
        if index >= levels.count - 6 { return Theme.record }
        return Theme.ink.opacity(0.25 + 0.75 * Double(index) / Double(levels.count))
    }
}

private struct Controls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Button { Task { await model.recorder.takeBreak() } } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.white))
                    .overlay(Circle().strokeBorder(Theme.field))
            }
            .buttonStyle(.plain)
            .help(L("recording.breakHelp"))
            .accessibilityLabel(L("recording.takeBreak"))
            .keyboardShortcut("k", modifiers: [.command, .option])

            StopButton()
        }
        .disabled(model.recorder.phase != .recording)
    }
}

private struct StopButton: View {
    @Environment(AppModel.self) private var model
    @State private var halo = false

    var body: some View {
        Button { Task { await model.recorder.stop() } } label: {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(.white)
                .frame(width: 14, height: 14)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Theme.record))
                .background(Circle().stroke(Theme.record.opacity(halo ? 0 : 0.35), lineWidth: halo ? 14 : 0).scaleEffect(halo ? 1.3 : 1))
                .shadow(color: Theme.record.opacity(0.24), radius: 6, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("recording.stop"))
        .keyboardShortcut("r", modifiers: [.command, .option])
        .onAppear {
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { halo = true }
        }
    }
}

private struct BreakPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = model.recorder.breakStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
                Text(elapsed.clock)
                    .font(.system(size: 46, weight: .medium).monospacedDigit())
                    .kerning(-1.6)
                    .foregroundStyle(Theme.secondary)
            }
            Text(L("recording.breakNote"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 6) {
                Button(L("recording.resume")) { Task { await model.recorder.resume() } }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                Button(L("recording.finish")) { Task { await model.recorder.stop() } }
                    .buttonStyle(PillButtonStyle(kind: .outline))
            }
        }
    }
}

private struct FailurePanel: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(L("recording.retry")) { model.record(model.recorder.course) }
                .buttonStyle(PillButtonStyle(kind: .primary))
        }
    }
}

struct PulsingDot: View {
    var active: Bool
    var color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(active && !pulse ? 0.5 : 0)).scaleEffect(active && pulse ? 2.4 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// The rounded field at the bottom: notes while recording, questions on a lecture page.
struct Composer: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    var placeholder = L("recording.addNote")
    var showsTools = true
    let send: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if showsTools {
                IconButton(systemName: "camera", label: L("recording.addPhoto"), size: 28) { addPhoto() }
                IconButton(systemName: "flag", label: L("recording.mark"), size: 28) { model.recorder.addNote(L("recording.marked")) }
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused(focused)
                .onSubmit(sendIfNeeded)
                .padding(.horizontal, 6)
            Button(action: sendIfNeeded) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color(hex: 0xCFCFCF) : Theme.ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("composer.send"))
        }
        .padding(.leading, showsTools ? 6 : 10)
        .padding(.trailing, 6)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Theme.field))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
    }

    private func sendIfNeeded() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(Theme.ease) { send() }
    }

    /// Copies chosen photos into the session's board folder; they are placed on the timeline later.
    private func addPhoto() {
        guard let session = model.recorder.session else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        let board = model.folder(of: session).appendingPathComponent("board", isDirectory: true)
        try? FileManager.default.createDirectory(at: board, withIntermediateDirectories: true)
        for url in panel.urls {
            let target = board.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.copyItem(at: url, to: target) }
        }
        model.recorder.addNote(L("recording.photoAdded", panel.urls.count))
    }
}
