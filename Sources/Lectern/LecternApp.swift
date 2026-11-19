import AppKit
import LecternCore
import SwiftUI

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
        // opened at login (to record meetings on their own) Lectern stays in the menu bar: no window
        // and no jump to the front. `--background` asks for the same by hand.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if atLogin || CommandLine.arguments.contains("--background") {
            for delay in [0.0, 0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard !NSApp.isActive else { return }
                    NSApp.windows.filter { $0.canBecomeMain && $0.isVisible }.forEach { $0.orderOut(nil) }
                }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A lecture keeps recording when the app quits. A meeting that began on its own is ended and
    /// added first: with the app gone nobody would notice that the call is over.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = AppModel.current?.recorder, recorder.automatic != nil, recorder.phase == .recording else {
            return .terminateNow
        }
        Task { @MainActor in
            await recorder.stopAutomatic(quitting: true)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        // recordings that arrived while the app was in the background (another recorder, a synced folder)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.recorder.isActive { model.reload() }
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
        if (try? credentials.codexAccount()) != nil { return "ChatGPT" }
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
            if MeetingSettings.canAutoRecord {
                Toggle(L("settings.meetings.auto"), isOn: Binding(get: { model.meetings.enabled },
                                                                 set: { model.meetings.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            }
            Button(L("menu.openWindow")) { AppWindow.bringForward() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }
}
