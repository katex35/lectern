import AppKit
import LecternCore
import Observation
import SwiftUI

/// Looks once a second at who holds the microphone and lets `AutoRecordPolicy` decide: a meeting app
/// on the microphone starts a recording, the end of the call ends it. The rules live in the policy;
/// this only reads the system, starts and stops the recorder and shows the two small panels.
@MainActor @Observable
final class MeetingWatcher {
    private(set) var enabled = false
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var policy = AutoRecordPolicy()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let reader = DispatchQueue(label: "lectern.meetings.audio-users")
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var panel: MeetingPanel?

    func start(_ model: AppModel, adopted: AutomaticRecording?) {
        self.model = model
        model.recorder.onAutomaticEnd = { [weak self] how, session in self?.ended(how, session) }
        // development: a shorter wait for the end of a call than three minutes
        if let quiet = ProcessInfo.processInfo.environment["LECTERN_MEETING_QUIET"].flatMap(Double.init) {
            policy.timing.stopAfter = quiet
        }
        if let adopted { policy.adopt(adopted, now: Date()) }
        setEnabled(MeetingSettings.autoRecords, save: false)
    }

    func setEnabled(_ on: Bool, save: Bool = true) {
        let on = on && MeetingSettings.canAutoRecord
        if save { UserDefaults.standard.set(on, forKey: MeetingSettings.autoRecordKey) }
        enabled = on
        policy.setEnabled(on, now: Date())
        refreshTimer()
    }

    /// The timer runs while there is something to watch for, or a recording of ours to end.
    private func refreshTimer() {
        let needed = enabled || policy.current != nil
        if needed, timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            // with no window on screen App Nap would slow the timer down and a call would be noticed late
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Watching for meetings")
        } else if !needed, let t = timer {
            t.invalidate()
            timer = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }

    /// The recorder is in use for something the policy did not start.
    private var busy: Bool {
        guard let recorder = model?.recorder else { return false }
        return !recorder.isIdle && recorder.automatic == nil
    }

    private func tick() {
        guard !reading else { return }
        reading = true
        reader.async { [weak self] in
            let users = AudioUsers.current()
            Task { @MainActor in self?.observed(users) }
        }
    }

    private func observed(_ users: [AudioUser]) {
        reading = false
        perform(policy.observe(users, recorderBusy: busy, now: Date()))
        refreshTimer()
    }

    private func perform(_ effects: [AutoRecordPolicy.Effect]) {
        guard let model else { return }
        for effect in effects {
            switch effect {
            case .start(let start):
                let title = L("meeting.titled", start.service ?? start.app.name)
                Task { await model.recorder.start(course: nil, meeting: .init(title: title, automatic: start.recording)) }
            case .stop:
                Task { await model.recorder.stopAutomatic() }
            case .readTabs(_, let token):
                perform(policy.tabsRead(token: token, found: nil, recorderBusy: busy, now: Date()))
            }
        }
    }

    private func ended(_ how: AutoRecordPolicy.End, _ session: Session?) {
        policy.ended(how, now: Date())
        refreshTimer()
        guard let model, let session, let recording = session.recordings.last, (recording.duration ?? 0) > 0 else { return }
        switch how {
        case .stoppedByUser:
            // stopped from the app: its page is what the user wants next
            model.open(session)
        case .finished:
            showAdded(session, recording: recording)
        case .rejected, .failed:
            break
        }
    }

    // MARK: panels

    private func show(_ content: MeetingNotice, for seconds: TimeInterval) {
        panel?.dismiss()
        let panel = MeetingPanel(content: content)
        self.panel = panel
        panel.show()
        Task { [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, let panel, self.panel === panel else { return }
            self.closePanel()
        }
    }

    private func closePanel() {
        panel?.dismiss()
        panel = nil
    }

    /// The recording is in the library: its name and length, the file in Finder, its page in Lectern.
    private func showAdded(_ session: Session, recording: RecordingInfo) {
        guard let model else { return }
        let file = model.library.folder(of: session).appendingPathComponent(recording.file)
        show(Self.addedNotice(title: session.title, duration: recording.duration ?? 0, show: { [weak self] in
            NSWorkspace.shared.activateFileViewerSelecting([file])
            self?.closePanel()
        }, open: { [weak self] in
            model.open(session)
            AppWindow.bringForward()
            self?.closePanel()
        }), for: 20)
    }

    static func addedNotice(title: String, duration: TimeInterval, show: @escaping () -> Void,
                            open: @escaping () -> Void) -> MeetingNotice {
        MeetingNotice(symbol: "checkmark.circle.fill", tint: Color(hex: 0x10B981), title: L("meeting.added.title"),
                      detail: "\(title) · \(duration.clock)",
                      secondary: .init(title: L("meeting.added.show"), run: show),
                      primary: .init(title: L("meeting.added.open"), run: open))
    }

    /// The panels with made-up content, for the development screenshots.
    static var sampleNotices: [(name: String, notice: MeetingNotice)] {
        [("added", addedNotice(title: L("meeting.titled", "Zoom"), duration: 2531, show: {}, open: {}))]
    }
}

/// The main window, also when it was closed or never shown (launched at login).
@MainActor
enum AppWindow {
    static func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
