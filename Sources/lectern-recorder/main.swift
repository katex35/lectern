// Records one microphone stream in its own process, so a crash or quit of the app does not stop it.
//
//   lectern-recorder <output.m4a> [--device ID] [--max-duration S] [--fragment S] [--system-audio]
//                    [--watchdog S] [--live]
//   lectern-recorder <output.m4a> --simulate S [--gap START:LENGTH]...     (tests, demos)
//   lectern-recorder --list-devices
//
// With --system-audio what the Mac plays is recorded next to the microphone (a meeting's other side)
// and mixed into the output once the recording stops. The microphone never waits for it.
// With --live the last two minutes of what the Mac plays are also kept in a small file next to the
// output while recording, for the app's live helper to listen in.
// With --watchdog the recording ends by itself when no SIGUSR1 arrived for that long: a meeting
// recorded automatically is ended by the app, and must not run on when the app is gone.
//
// Events go to stdout as JSON lines: ready, level, gap, system (state "recording" once something the
// Mac plays was heard, "failed" with an error), mixing, finished, failed. SIGINT or
// SIGTERM stops and finalizes the file. Exit status: 0 finished, 2 could not start, 3 finished with
// an error.
import Foundation
import LecternCore

setvbuf(stdout, nil, _IOLBF, 0)
// the app may quit while we record: a closed stdout must not kill the process
signal(SIGPIPE, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let lineEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
}()

struct Line: Encodable {
    var event: String
    var start: Date?
    var rms: Float?
    var peak: Float?
    var gap: RecordingGap?
    var report: RecordingReport?
    var error: String?
    /// For `system`: "recording" once the computer's audio arrives, "failed" with `error` otherwise.
    var state: String?
    var devices: [Device]?

    struct Device: Encodable {
        var id: String
        var name: String
        var builtIn: Bool
    }
}

func emit(_ line: Line) {
    guard var data = try? lineEncoder.encode(line) else { return }
    data.append(0x0A)
    // write errors (reader gone) are ignored: recording goes on
    _ = data.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

if args == ["--list-devices"] {
    emit(Line(event: "devices", devices: Recorder.inputDevices().map { .init(id: $0.id, name: $0.name, builtIn: $0.isBuiltIn) }))
    exit(0)
}

var config = RecorderConfiguration()
if let v = option("--max-duration").flatMap(Double.init) { config.maxDuration = v }
if let v = option("--fragment").flatMap(Double.init) { config.fragmentInterval = v }
let deviceID = option("--device")
let watchdogSeconds = option("--watchdog").flatMap(Double.init)
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
let wantsSystemAudio = flag("--system-audio")
let wantsLive = flag("--live")
let simulate = option("--simulate").flatMap(Double.init)
var gaps: [(Double, Double)] = []
while let g = option("--gap") {
    let p = g.split(separator: ":").compactMap { Double($0) }
    if p.count == 2 { gaps.append((p[0], p[1])) }
}
guard args.count == 1 else {
    FileHandle.standardError.write(Data("usage: lectern-recorder <output.m4a> [--device ID] [--max-duration S]\n".utf8))
    exit(2)
}

let output = URL(fileURLWithPath: args[0])
let recorder = Recorder(output: output, configuration: config)
let systemAudio: SystemAudioRecorder? = wantsSystemAudio
    ? SystemAudioRecorder(output: RecordingTracks.system(for: output), configuration: config,
                          live: wantsLive ? RecordingTracks.live(for: output) : nil) : nil
systemAudio?.onEvent = { event in
    switch event {
    case .heard: emit(Line(event: "system", state: "recording"))
    case .problem(let message): emit(Line(event: "system", error: message, state: "failed"))
    }
}
var exiting = false

/// The microphone file is final. The computer's audio, if it was recorded, is closed and mixed in
/// before the one `finished` line: the app never sees a recording that is still changing.
@Sendable func finish(_ microphone: RecordingReport) async -> Never {
    var report = microphone
    if let systemAudio {
        let track = await systemAudio.stop()
        if track != nil, TrackMerger.isPending(output) {
            emit(Line(event: "mixing"))
            report.systemAudio = TrackMerger.mixPending(output)
        } else {
            report.systemAudio = SystemAudioReport(status: .failed, error: systemAudio.problem ?? "no audio arrived from the computer")
        }
        // the report next to the file is what an app that was not listening reads
        try? JSONStore.write(report, to: RecordingReport.sidecar(for: output))
    }
    emit(Line(event: "finished", report: report))
    exit(report.status == .finished ? 0 : 3)
}

recorder.onEvent = { event in
    switch event {
    case .level(let rms, let peak): emit(Line(event: "level", rms: rms, peak: peak))
    case .gap(let gap): emit(Line(event: "gap", gap: gap))
    case .stopped(let report):
        guard !exiting else { return }
        exiting = true
        Task { await finish(report) }
    }
}

let signalSources = [SIGINT, SIGTERM].map { s -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: s, queue: .main)
    source.setEventHandler {
        guard !exiting else { return }
        exiting = true
        Task { await finish(await recorder.stop()) }
    }
    source.resume()
    return source
}

// SIGUSR1 means "the app is still here". Counted on a clock that stops while the Mac sleeps, so
// waking up does not look like a long silence.
var lastHeartbeat = ProcessInfo.processInfo.systemUptime
var watchdogSources: [any DispatchSourceProtocol] = []
if let watchdogSeconds {
    signal(SIGUSR1, SIG_IGN)
    let beat = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    beat.setEventHandler { lastHeartbeat = ProcessInfo.processInfo.systemUptime }
    beat.resume()
    let check = DispatchSource.makeTimerSource(queue: .main)
    check.schedule(deadline: .now() + 5, repeating: 5)
    check.setEventHandler {
        guard !exiting, ProcessInfo.processInfo.systemUptime - lastHeartbeat > watchdogSeconds else { return }
        exiting = true
        Task { await finish(await recorder.stop()) }
    }
    check.resume()
    watchdogSources = [beat, check]
}

if let simulate {
    recorder.startSimulated(duration: simulate, gaps: gaps)
    emit(Line(event: "ready", start: Date()))
    systemAudio?.startSimulated(duration: simulate)
} else {
    Task {
        do {
            let device = deviceID.flatMap { id in Recorder.inputDevices().first { $0.id == id } }
            let start = try await recorder.start(device: device)
            emit(Line(event: "ready", start: start))
            systemAudio?.start()
        } catch {
            emit(Line(event: "failed", error: error.localizedDescription))
            exit(2)
        }
    }
}

withExtendedLifetime((signalSources, watchdogSources)) { dispatchMain() }
