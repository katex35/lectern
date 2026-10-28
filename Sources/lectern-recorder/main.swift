// Records one microphone stream in its own process, so a crash or quit of the app does not stop it.
//
//   lectern-recorder <output.m4a> [--device ID] [--max-duration S] [--fragment S]
//   lectern-recorder <output.m4a> --simulate S [--gap START:LENGTH]...     (tests, demos)
//   lectern-recorder --list-devices
//
// Events go to stdout as JSON lines: ready, level, gap, finished, failed. SIGINT or SIGTERM stops
// and finalizes the file. Exit status: 0 finished, 2 could not start, 3 finished with an error.
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

let recorder = Recorder(output: URL(fileURLWithPath: args[0]), configuration: config)
var exiting = false

@Sendable func finish(_ report: RecordingReport) -> Never {
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
        finish(report)
    }
}

let signalSources = [SIGINT, SIGTERM].map { s -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: s, queue: .main)
    source.setEventHandler {
        guard !exiting else { return }
        exiting = true
        Task { finish(await recorder.stop()) }
    }
    source.resume()
    return source
}

if let simulate {
    recorder.startSimulated(duration: simulate, gaps: gaps)
    emit(Line(event: "ready", start: Date()))
} else {
    Task {
        do {
            let device = deviceID.flatMap { id in Recorder.inputDevices().first { $0.id == id } }
            let start = try await recorder.start(device: device)
            emit(Line(event: "ready", start: start))
        } catch {
            emit(Line(event: "failed", error: error.localizedDescription))
            exit(2)
        }
    }
}

withExtendedLifetime(signalSources) { dispatchMain() }
