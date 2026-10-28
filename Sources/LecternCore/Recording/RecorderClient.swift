import Foundation

/// Drives the `lectern-recorder` helper process. The helper owns the microphone and the file; this
/// side only starts it, listens to its JSON-line events and stops it. If the app quits or crashes the
/// helper keeps recording, and a relaunched app reattaches with `attach(pid:output:)`.
public final class RecorderClient: @unchecked Sendable {
    public enum Event: Sendable {
        case level(rms: Float, peak: Float)
        case gap(RecordingGap)
        /// The recording ended without a stop request (error or maximum length).
        case ended(RecordingReport)
    }

    public let output: URL
    public private(set) var pid: Int32?
    /// Delivered on the main queue.
    public var onEvent: (@Sendable (Event) -> Void)?

    private let helper: URL?
    private var process: Process?
    private let lock = NSLock()
    private var buffer = Data()
    private var readyWaiter: CheckedContinuation<Date, Error>?
    private var stopWaiters: [CheckedContinuation<RecordingReport?, Never>] = []
    private var finalReport: RecordingReport?
    private var stopRequested = false
    private var ended = false

    struct Line: Decodable {
        var event: String
        var start: Date?
        var rms: Float?
        var peak: Float?
        var gap: RecordingGap?
        var report: RecordingReport?
        var error: String?
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
        guard isAlive(pid) else { return nil }
        return RecorderClient(attachedTo: pid, output: output)
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Starts the helper and returns the wall-clock time of the first sample once audio flows.
    public func start(deviceID: String? = nil, maxDuration: Double? = nil, simulate: Double? = nil,
                      gaps: [(Double, Double)] = []) async throws -> Date {
        guard let helper else { throw RecorderError.failed("attached client cannot start") }
        let p = Process()
        p.executableURL = helper
        var arguments = [output.path]
        if let deviceID { arguments += ["--device", deviceID] }
        if let maxDuration { arguments += ["--max-duration", String(maxDuration)] }
        if let simulate { arguments += ["--simulate", String(simulate)] }
        for g in gaps { arguments += ["--gap", "\(g.0):\(g.1)"] }
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

    /// Stops the recording and waits until the file is finalized (at most 60 s).
    @discardableResult
    public func stop() async -> RecordingReport? {
        if let r = lock.withLock({ finalReport }) { return r }
        guard let pid else { return nil }
        let first: Bool = lock.withLock {
            defer { stopRequested = true }
            return !stopRequested
        }
        if first { kill(pid, SIGINT) }
        if process == nil {
            // attached: no pipe to read, poll until the process is gone, then read the report
            for _ in 0..<300 {
                if !Self.isAlive(pid) { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let r = sidecarReport()
            lock.withLock { finalReport = r }
            return r
        }
        let report = await withCheckedContinuation { cont in
            let done: RecordingReport?? = lock.withLock {
                if ended { return .some(finalReport) }
                stopWaiters.append(cont)
                return nil
            }
            if let done { cont.resume(returning: done) }
        }
        // the file is final once "finished" arrives; also wait for the helper to exit, so quitting
        // right after Stop never leaves it half-way
        for _ in 0..<250 where process?.isRunning == true {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
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
