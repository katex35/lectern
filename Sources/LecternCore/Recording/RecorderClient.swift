import Foundation

/// Drives the `lectern-recorder` helper process. The helper owns the microphone and the file; this
/// side only starts it, listens to its JSON-line events and stops it. If the app quits or crashes the
/// helper keeps recording, and a relaunched app reattaches with `attach(pid:output:)`.
public final class RecorderClient: @unchecked Sendable {
    public enum Event: Sendable {
        case level(rms: Float, peak: Float)
        case gap(RecordingGap)
        /// The computer's audio is arriving (meetings recorded with `systemAudio`).
        case systemAudioStarted
        /// The computer's audio cannot be recorded; the microphone goes on alone.
        case systemAudioProblem(String)
        /// The recording ended without a stop request (error or maximum length).
        case ended(RecordingReport)
    }

    public let output: URL
    public private(set) var pid: Int32?
    /// Delivered on the main queue.
    public var onEvent: (@Sendable (Event) -> Void)?
    /// How long `stop()` waits for the helper to finalize (and mix) the file before giving up on it.
    public var stopTimeout: Double = 900

    private let helper: URL?
    private var process: Process?
    private let lock = NSLock()
    private var buffer = Data()
    private var readyWaiter: CheckedContinuation<Date, Error>?
    private var stopWaiters: [CheckedContinuation<RecordingReport?, Never>] = []
    private var finalReport: RecordingReport?
    private var stopRequested = false
    private var ended = false
    /// The helper ends the recording by itself when `heartbeat()` stops coming.
    private var watched = false

    /// True for a client that took over a helper another instance of the app started: it gets no
    /// events, so whoever holds it looks at `isRunning` now and then.
    public var isAttached: Bool { helper == nil }
    /// True while the helper this client drives is still there. For a helper taken over after a
    /// restart the process id is checked to still be that recorder every time: once it has exited,
    /// the number may belong to any other program, and signals sent to it would hit that program.
    public var isRunning: Bool {
        if let process { return process.isRunning }
        guard let pid else { return false }
        return Self.isRecording(pid: pid, output: output)
    }

    struct Line: Decodable {
        var event: String
        var start: Date?
        var rms: Float?
        var peak: Float?
        var gap: RecordingGap?
        var report: RecordingReport?
        var error: String?
        var state: String?
    }

    static let lineDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(helper: URL, output: URL) {
        self.helper = helper
        self.output = output
    }

    private init(attachedTo pid: Int32, output: URL) {
        self.helper = nil
        self.output = output
        self.pid = pid
    }

    /// The helper inside an app bundle, or next to the running executable during development.
    public static func defaultHelper() -> URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("lectern-recorder")
    }

    /// Reattaches to a helper that is still recording `output` (after the app restarted).
    /// Returns nil when that process is gone.
    public static func attach(pid: Int32, output: URL) -> RecorderClient? {
        guard isRecording(pid: pid, output: output) else { return nil }
        let client = RecorderClient(attachedTo: pid, output: output)
        client.watched = commandLine(of: pid)?.contains("--watchdog") == true
        return client
    }

    /// Tells a helper started with `watchdog` that the app is still there. Without one for that long
    /// the helper ends the recording itself: an automatic recording must not run on with nobody
    /// left to notice that the call is over.
    public func heartbeat() {
        guard watched, let pid, !lock.withLock({ ended || stopRequested }), isRunning else { return }
        kill(pid, SIGUSR1)
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// True when `pid` is a recorder helper writing `output`. A process id alone proves nothing: after
    /// a restart it may belong to any other program, and stopping sends it a signal.
    public static func isRecording(pid: Int32, output: URL) -> Bool {
        guard pid > 0, isAlive(pid), let command = commandLine(of: pid), let program = command.first else { return false }
        guard URL(fileURLWithPath: program).lastPathComponent == "lectern-recorder" else { return false }
        let wanted = output.standardizedFileURL.path
        return command.dropFirst().contains { URL(fileURLWithPath: $0).standardizedFileURL.path == wanted }
    }

    /// The program and arguments `pid` was started with, nil when it cannot be read.
    /// True if the recorder running as `pid` was started with `flag`.
    public static func recorder(_ pid: Int32, wasStartedWith flag: String) -> Bool {
        commandLine(of: pid)?.contains(flag) ?? false
    }

    static func commandLine(of pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        // layout: argc, the program's path, padding zeros, then argc strings
        var i = MemoryLayout<Int32>.size
        func string() -> String? {
            guard i < size else { return nil }
            let start = i
            while i < size, bytes[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
        guard let program = string() else { return nil }
        while i < size, bytes[i] == 0 { i += 1 }
        var arguments: [String] = []
        for _ in 0..<max(0, count) {
            guard let argument = string() else { break }
            arguments.append(argument)
        }
        // argv[0] repeats the program
        return [program] + arguments.dropFirst()
    }

    /// Starts the helper and returns the wall-clock time of the first sample once audio flows.
    /// With `systemAudio` what the Mac plays is recorded too and mixed in when the recording stops.
    public func start(deviceID: String? = nil, maxDuration: Double? = nil, simulate: Double? = nil,
                      gaps: [(Double, Double)] = [], systemAudio: Bool = false,
                      watchdog: Double? = nil, live: Bool = false) async throws -> Date {
        guard let helper else { throw RecorderError.failed("attached client cannot start") }
        let p = Process()
        p.executableURL = helper
        var arguments = [output.path]
        if let deviceID { arguments += ["--device", deviceID] }
        if let maxDuration { arguments += ["--max-duration", String(maxDuration)] }
        if let simulate { arguments += ["--simulate", String(simulate)] }
        for g in gaps { arguments += ["--gap", "\(g.0):\(g.1)"] }
        if systemAudio { arguments.append("--system-audio") }
        if systemAudio, live { arguments.append("--live") }
        if let watchdog {
            arguments += ["--watchdog", String(watchdog)]
            watched = true
        }
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] proc in self?.exited(status: proc.terminationStatus) }
        return try await withCheckedThrowingContinuation { cont in
            lock.withLock { readyWaiter = cont }
            do {
                try p.run()
                process = p
                pid = p.processIdentifier
            } catch {
                let w = lock.withLock { () -> CheckedContinuation<Date, Error>? in
                    defer { readyWaiter = nil }
                    return readyWaiter
                }
                w?.resume(throwing: RecorderError.failed("cannot launch recorder: \(error.localizedDescription)"))
            }
        }
    }

    /// Stops the recording and waits until the file is finalized, and mixed with the computer's audio
    /// when that was recorded (at most `stopTimeout`).
    @discardableResult
    public func stop() async -> RecordingReport? {
        if let r = lock.withLock({ finalReport }) { return r }
        guard let pid else { return nil }
        let first: Bool = lock.withLock {
            defer { stopRequested = true }
            return !stopRequested
        }
        if first, isRunning { kill(pid, SIGINT) }
        if process == nil {
            // attached: no pipe to read, poll until the process is gone, then read the report
            let deadline = Date().addingTimeInterval(stopTimeout)
            while isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            var r = sidecarReport()
            if isRunning {
                // still writing: nobody may treat the file as final while it does. It is ended for
                // good; the next launch repairs the file up to its last fragment.
                kill(pid, SIGKILL)
                for _ in 0..<50 where isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
                r = Self.timedOut(r)
            }
            lock.withLock { finalReport = r }
            return r
        }
        let report = await withCheckedContinuation { cont in
            let done: RecordingReport?? = lock.withLock {
                if ended { return .some(finalReport) }
                stopWaiters.append(cont)
                return nil
            }
            if let done { return cont.resume(returning: done) }
            // A helper that neither finishes nor exits must not leave Stop waiting forever, and nobody
            // may treat its file as final while it still writes: it is ended for good first. The next
            // launch repairs the file up to its last fragment.
            DispatchQueue.global().asyncAfter(deadline: .now() + stopTimeout) { [weak self] in
                guard let self, !self.lock.withLock({ self.ended }) else { return }
                self.conclude(Self.timedOut(self.sidecarReport()))
                kill(pid, SIGKILL)
            }
        }
        // the file is final once "finished" arrives; also wait for the helper to exit, so quitting
        // right after Stop never leaves it half-way
        for _ in 0..<250 where process?.isRunning == true {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return report
    }

    static func timedOut(_ last: RecordingReport?) -> RecordingReport {
        var report = last ?? RecordingReport(status: .failed, start: nil, duration: 0, device: "", deviceID: "", gaps: [],
                                             deviceChanges: [], backwardJumps: 0, error: nil)
        report.status = .failed
        report.error = "The recorder did not finish in time and was stopped; the recording is recovered up to its last moments."
        return report
    }

    /// The report the helper keeps next to the file (live while recording, final after).
    public func sidecarReport() -> RecordingReport? {
        try? JSONStore.read(RecordingReport.self, from: RecordingReport.sidecar(for: output))
    }

    // MARK: - helper output

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        for raw in lines {
            guard let line = try? Self.lineDecoder.decode(Line.self, from: raw) else { continue }
            handle(line)
        }
    }

    private func handle(_ line: Line) {
        switch line.event {
        case "ready":
            let w = lock.withLock { () -> CheckedContinuation<Date, Error>? in
                defer { readyWaiter = nil }
                return readyWaiter
            }
            w?.resume(returning: line.start ?? Date())
        case "failed":
            let w = lock.withLock { () -> CheckedContinuation<Date, Error>? in
                defer { readyWaiter = nil }
                return readyWaiter
            }
            w?.resume(throwing: RecorderError.failed(line.error ?? "recording could not start"))
        case "level":
            if let rms = line.rms, let peak = line.peak { deliver(.level(rms: rms, peak: peak)) }
        case "gap":
            if let gap = line.gap { deliver(.gap(gap)) }
        case "system":
            deliver(line.state == "recording" ? .systemAudioStarted : .systemAudioProblem(line.error ?? ""))
        case "finished":
            if let report = line.report { conclude(report) }
        default:
            break
        }
    }

    private func exited(status: Int32) {
        // the pipe may still hold the last lines; give the reader a moment, then fall back to the sidecar
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let w = self.lock.withLock { () -> CheckedContinuation<Date, Error>? in
                defer { self.readyWaiter = nil }
                return self.readyWaiter
            }
            w?.resume(throwing: RecorderError.failed("recorder exited (status \(status)) before audio started"))
            if !self.lock.withLock({ self.ended }) {
                let report = self.sidecarReport() ?? RecordingReport(
                    status: .failed, start: nil, duration: 0, device: "", deviceID: "", gaps: [], deviceChanges: [],
                    backwardJumps: 0, error: "recorder exited with status \(status)")
                self.conclude(report)
            }
        }
    }

    private func conclude(_ report: RecordingReport) {
        let (waiters, unrequested): ([CheckedContinuation<RecordingReport?, Never>], Bool) = lock.withLock {
            guard !ended else { return ([], false) }
            ended = true
            finalReport = report
            let w = stopWaiters
            stopWaiters = []
            return (w, !stopRequested)
        }
        waiters.forEach { $0.resume(returning: report) }
        if unrequested { deliver(.ended(report)) }
    }

    private func deliver(_ event: Event) {
        guard let handler = onEvent else { return }
        DispatchQueue.main.async { handler(event) }
    }
}
