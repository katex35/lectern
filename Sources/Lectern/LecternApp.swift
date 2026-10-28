import AppKit
import LecternCore
import SwiftUI

@main
struct LecternApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(library: AppModel.defaultLibrary())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("menu.record")) { model.record(nil) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button(L("menu.meeting")) { model.record(nil, meeting: true) }
            }
            CommandGroup(after: .sidebar) {
                Button(L("menu.toggleSidebar")) { withAnimation(Theme.ease) { model.sidebarVisible.toggle() } }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button(L("menu.search")) { withAnimation(Theme.quick) { model.searching.toggle() } }
                    .keyboardShortcut("k", modifiers: [.command])
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel(recorder: model.recorder)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.light)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // started with `swift run` there is no bundle telling macOS this is a regular app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Notices are planned a week ahead; coming back to the app moves that week along.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in await Reminders.shared.plan() }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if model.sidebarVisible {
                SidebarView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                TopBar()
                ZStack {
                    switch model.screen {
                    case .home:
                        HomeView().transition(.opacity)
                    case .recording:
                        RecordingView().transition(.opacity)
                    case .session(let ref):
                        SessionView(ref: ref).id(ref).transition(.opacity)
                    case .archive(let filter):
                        ArchiveView(filter: filter).transition(.opacity)
                    case .schedule:
                        ScheduleView().transition(.opacity)
                    case .exam(let courseID):
                        ExamView(courseID: courseID).id(courseID).transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.white)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(.white)
        // photos dropped anywhere else find their lecture by the time they were taken
        .dropDestination(for: URL.self) { urls, _ in
            model.importPhotos(urls)
            return urls.contains(where: BoardPhotos.isPhoto)
        }
        .sheet(item: $model.editingCourse) { draft in
            CourseSheet(draft: draft)
                .environment(model)
        }
        .overlay {
            if model.searching {
                SearchPanel().transition(.opacity)
            }
        }
        .task { await Snapshots.runIfRequested(model, openSettings: openSettings) }
    }
}

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if !model.sidebarVisible {
                // traffic lights sit here when the sidebar is closed
                Color.clear.frame(width: 70, height: 1)
            }
            IconButton(systemName: "sidebar.left", label: L("menu.toggleSidebar")) {
                withAnimation(Theme.ease) { model.sidebarVisible.toggle() }
            }
            // the service writing notes; opens the accounts in Settings, like a model picker
            SettingsLink {
                HStack(spacing: 4) {
                    Text(model.noteModelName)
                        .font(.system(size: 14, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle(radius: 7))
            Spacer()
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(Color(hex: 0xF4F4F4)))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.recorder.isActive, model.screen != .recording {
                Button { withAnimation(Theme.ease) { model.screen = .recording } } label: {
                    HStack(spacing: 6) {
                        PulsingDot(active: true, color: Theme.record)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(model.recorder.elapsed(at: context.date).clock)
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(Color(hex: 0xFFF1F1)))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }
}

/// Which service writes notes, as the top bar shows it.
@MainActor
enum ProviderSummary {
    static func noteModel() -> String {
        let credentials = Credentials(store: KeychainStore(service: SettingsView.keychainService))
        if (try? credentials.chatGPTAccount())?.canUsePlan == true { return "ChatGPT" }
        if (try? credentials.apiKey(for: .anthropic)) != nil { return "Claude" }
        if (try? credentials.apiKey(for: .gemini)) != nil { return "Gemini" }
        if (try? credentials.apiKey(for: .openAI)) != nil { return "OpenAI" }
        return L("top.noModel")
    }
}

private struct MenuBarLabel: View {
    let recorder: RecordingController

    var body: some View {
        if recorder.phase == .recording {
            Text(verbatim: "● \(recorder.elapsed(at: recorder.tick).clock)")
                .monospacedDigit()
        } else {
            Image(systemName: "waveform")
        }
    }
}

private struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let recorder = model.recorder
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                CoverView(course: recorder.course ?? model.currentLecture ?? model.nextLecture?.course, width: 30, height: 30, radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recorder.course?.shortName ?? model.currentLecture?.shortName ?? model.nextLecture?.course.shortName ?? "Lectern")
                        .font(.system(size: 14, weight: .semibold))
                    Text(recorder.isActive ? L("recording.live") : model.nextLecture.map { RelativeTime.dayAndTime($0.start) } ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            if recorder.phase == .recording {
                HStack(spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(recorder.elapsed(at: context.date).clock)
                            .font(.system(size: 34, weight: .medium).monospacedDigit())
                            .kerning(-1)
                    }
                    LiveWave(levels: Array(recorder.levels.suffix(18)), running: true)
                        .frame(height: 30)
                        .scaleEffect(0.6, anchor: .leading)
                }
                HStack(spacing: 6) {
                    TextField(L("recording.addNote"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { recorder.addNote(draft); draft = "" }
                    Button { Task { await recorder.takeBreak() } } label: { Image(systemName: "pause.fill") }
                        .help(L("recording.takeBreak"))
                }
                Button(L("recording.stop")) { Task { await recorder.stop() } }
                    .buttonStyle(PillButtonStyle(kind: .danger))
            } else if recorder.phase == .onBreak {
                Button(L("recording.resume")) { Task { await recorder.resume() } }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            } else {
                Button(L("home.record")) { model.record(nil) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
            Button(L("menu.openWindow")) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }
}
