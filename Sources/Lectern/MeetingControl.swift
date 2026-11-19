import AppKit
import LecternCore

/// Meetings from a terminal or a script:
///
///     Lectern --meeting status            what is being recorded, and whether meetings start on their own
///     Lectern --meeting start             record a meeting now (opens Lectern in the background if needed)
///     Lectern --meeting stop              end the recording and wait until it is in the library
///     Lectern --meeting auto on|off       turn automatic recording on or off
///
/// The command talks to the running app through notifications, prints the answer as JSON and exits:
/// 0 done, 1 Lectern did not answer, 2 it could not be done.
///
/// Any program on this Mac can send such a notification, so the app only listens when the user turned
/// "Let the command line start and stop meetings" on in Settings. Without it the app answers that it
/// runs and nothing more.
enum MeetingControl {
    private static let domain = Bundle.main.bundleIdentifier ?? "app.lectern"
    private static let request = Notification.Name("\(domain).meeting.request")
    private static let reply = Notification.Name("\(domain).meeting.reply")

    // MARK: the command

    /// The command and its argument when the process was started as one.
    static func command(in arguments: [String]) -> [String]? {
        guard let i = arguments.firstIndex(of: "--meeting") else { return nil }
        return Array(arguments[(i + 1)...])
    }

    static func run(_ words: [String]) -> Int32 {
        let command = words.joined(separator: " ")
        guard ["status", "start", "stop", "auto on", "auto off"].contains(command) else {
            FileHandle.standardError.write(Data("usage: Lectern --meeting status | start | stop | auto on | auto off\n".utf8))
            return 2
        }
        let id = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        // the app first says that it heard, then sends the result; only the result ends the wait
        var heard = false
        var result: [AnyHashable: Any]?
        let observer = center.addObserver(forName: reply, object: id, queue: .main) { note in
            heard = true
            if note.userInfo?["json"] != nil { result = note.userInfo }
        }
        defer { center.removeObserver(observer) }
        func wait(_ seconds: TimeInterval, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        }
        func ask() {
            center.postNotificationName(request, object: id, userInfo: ["command": command], deliverImmediately: true)
        }
        ask()
        wait(2) { heard }
        if !heard, command == "start" || command == "auto on" {
            // not running: opened without a window, then asked again until it is up
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = ["--background"]
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            for _ in 0..<15 where !heard {
                ask()
                wait(1) { heard }
            }
        }
        guard heard else {
            print("{\"running\": false}")
            return 1
        }
        // a stop mixes the recording first: that can take minutes for a long meeting
        wait(1200) { result != nil }
        guard let result, let json = result["json"] as? String else { return 1 }
        print(json)
        return result["failed"] == nil ? 0 : 2
    }

    // MARK: the app

    @MainActor
    static func listen(_ model: AppModel) {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: request, object: nil, queue: .main) { [weak model] note in
            guard let id = note.object as? String, let command = note.userInfo?["command"] as? String else { return }
            Task { @MainActor in
                // a command that had to wake the app asks more than once: it is carried out once
                guard let model, answered.insert(id).inserted else { return }
                // heard: the command knows the app is there and waits for the result
                center.postNotificationName(reply, object: id, userInfo: ["pending": "1"], deliverImmediately: true)
                guard MeetingSettings.allowsControl else {
                    // not turned on by the user: nothing is done and nothing about recordings is told
                    let refusal: [String: Any] = ["running": true, "error": "Turn on \"\(L("settings.meetings.control"))\" in Lectern's Settings first."]
                    center.postNotificationName(reply, object: id, userInfo: ["json": json(refusal), "failed": "1"], deliverImmediately: true)
                    return
                }
                let failure = await perform(command, model)
                var answer = ["json": json(status(model, error: failure))]
                if failure != nil { answer["failed"] = "1" }
                center.postNotificationName(reply, object: id, userInfo: answer, deliverImmediately: true)
            }
        }
    }

    /// Requests already taken up, by their id.
    @MainActor private static var answered = Set<String>()

    /// Returns what went wrong, nil when the command was carried out.
    @MainActor
    private static func perform(_ command: String, _ model: AppModel) async -> String? {
        let recorder = model.recorder
        // these commands are about meetings: a lecture is never started, taken for one or stopped by them
        let lecture = !recorder.isIdle && recorder.session?.kind == .lecture && recorder.phase != .starting
        switch command {
        case "start":
            if recorder.phase == .recording, !lecture { return nil }
            guard recorder.canStart else { return lecture ? "a lecture is being recorded" : "the recorder is busy" }
            await recorder.start(course: nil)
            if case .failed(let message) = recorder.phase { return message }
            return recorder.phase == .recording ? nil : "recording did not start"
        case "stop":
            guard recorder.phase == .recording else { return "nothing is being recorded" }
            guard !lecture else { return "a lecture is being recorded" }
            await recorder.stop()
            return nil
        case "auto on":
            model.meetings.setEnabled(true)
            return model.meetings.enabled ? nil : "automatic recording needs macOS 14.2 or later"
        case "auto off":
            model.meetings.setEnabled(false)
            return nil
        default:
            return nil
        }
    }

    @MainActor
    private static func status(_ model: AppModel, error: String?) -> [String: Any] {
        let recorder = model.recorder
        var status: [String: Any] = [
            "running": true,
            "recording": recorder.phase == .recording,
            "automatic": model.meetings.enabled,
            "window": NSApp.windows.contains { $0.canBecomeMain && $0.isVisible },
            // who has the microphone open right now, as the watcher sees it
            "microphone": AudioUsers.current().filter(\.input).map { $0.bundle.isEmpty ? $0.path : $0.bundle },
        ]
        if let error { status["error"] = error }
        // the session being recorded, or the one that was just closed
        if let session = recorder.session, let file = recorder.file ?? session.recordings.last?.file {
            let fresh = model.library.reload(session) ?? session
            status["title"] = fresh.title
            status["folder"] = model.library.folder(of: fresh).path
            status["file"] = file
            if recorder.phase == .recording {
                status["seconds"] = Int(recorder.elapsed(at: Date()))
                status["startedByItself"] = recorder.automatic != nil
                switch recorder.systemAudio {
                case .recording: status["computerAudio"] = "recording"
                case .waiting: status["computerAudio"] = "nothing heard yet"
                case .problem(let message): status["computerAudio"] = "failed: \(message)"
                case .off: status["computerAudio"] = "off"
                }
            } else if let recording = fresh.recordings.first(where: { $0.file == file }) {
                status["seconds"] = Int(recording.duration ?? 0)
                if let heard = recording.systemAudio { status["computerAudio"] = heard.status.rawValue }
            }
        }
        return status
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The process starts here: as the app, or as a command to the app that is already running.
@main
enum Entry {
    static func main() {
        if let words = MeetingControl.command(in: CommandLine.arguments) {
            exit(MeetingControl.run(words))
        }
        LecternApp.main()
    }
}
