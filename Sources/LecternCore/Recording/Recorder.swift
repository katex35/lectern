import AVFoundation
import Foundation
import IOKit.pwr_mgt

public enum RecorderError: LocalizedError, Equatable {
    case permissionDenied
    case noMicrophone
    case fileExists(String)
    case cannotOpen(String)
    case noAudio
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
        case .noMicrophone: return "No microphone was found."
        case .fileExists(let path): return "A recording already exists at \(path)."
        case .cannotOpen(let name): return "Could not open \(name)."
        case .noAudio: return "The microphone delivered no audio within 10 seconds."
        case .failed(let message): return message
        }
    }
}

/// Records one microphone stream to an AAC .m4a file without dropping buffers.
///
/// The file's length always equals wall-clock time: when no audio arrives (sleep, lid closed, device
/// removed) that stretch is written as silence and reported as a gap. The file is written in fragments,
/// so after a crash it opens up to the last fragment. While recording, a report sidecar next to the
/// file (`RecordingReport.sidecar(for:)`) holds the start time, gaps and device changes.
public final class Recorder: @unchecked Sendable {
    public enum Event: Sendable {
        /// About ten times a second: RMS and peak in dBFS.
        case level(rms: Float, peak: Float)
        case gap(RecordingGap)
        /// The recording stopped on its own (error or maximum length).
        case stopped(RecordingReport)
    }

    public let output: URL
    public let configuration: RecorderConfiguration
    /// Delivered on the main queue.
    public var onEvent: (@Sendable (Event) -> Void)?

    private var pipeline: AudioPipeline?
    private var microphone: MicrophoneSource?
    private var watchdog: DispatchSourceTimer?
    private var sleepAssertion: IOPMAssertionID = 0
    private let lock = NSLock()
    private var finalReport: RecordingReport?
    private var stopWaiters: [CheckedContinuation<RecordingReport, Never>] = []
    private var stopping = false

    public init(output: URL, configuration: RecorderConfiguration = .init()) {
        self.output = output
        self.configuration = configuration
    }

    public static func inputDevices() -> [AudioInputDevice] { AudioDevices.list() }

    /// Asks for microphone access if it was never asked; true when recording is allowed.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Starts recording and returns once audio is actually flowing, with the wall-clock time of the
    /// first sample. Throws when recording cannot start; no file is left behind then.
    public func start(device: AudioInputDevice? = nil) async throws -> Date {
        // never write over an existing recording
        guard !FileManager.default.fileExists(atPath: output.path) else { throw RecorderError.fileExists(output.path) }
        guard await Self.requestAccess() else { throw RecorderError.permissionDenied }
        guard let captureDevice = AudioDevices.resolve(device) else { throw RecorderError.noMicrophone }
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: RecordingReport.sidecar(for: output))

        let p = AudioPipeline(output: output, config: configuration, realTime: true)
        let mic: MicrophoneSource
        do {
            mic = try MicrophoneSource(pipeline: p, device: captureDevice)
        } catch {
            throw RecorderError.cannotOpen(captureDevice.localizedName)
        }
        pipeline = p
        microphone = mic
        wire(p)

        // keep the Mac from idling to sleep while recording (closing the lid still cuts the microphone)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "Recording a lecture" as CFString,
                                    &sleepAssertion)

        let started: Date = try await withCheckedThrowingContinuation { cont in
            var resumed = false
            let opened = monotonicNow()
            p.onReady = { report in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: report.start ?? Date())
            }
            let previousFinish = p.onFinish
            p.onFinish = { report in
                previousFinish(report)
                guard !resumed else { return }
                resumed = true
                cont.resume(throwing: RecorderError.failed(report.error ?? "recording could not start"))
            }
            startWatchdog(p, mic: mic, opened: opened) {
                guard !resumed else { return }
                resumed = true
                p.error = "no audio arrived from the microphone"
                p.closing = true
                cont.resume(throwing: RecorderError.noAudio)
            }
            mic.start()
        }
        return started
    }

    /// Stops and finalizes the file. Safe to call more than once and after the recorder stopped itself.
    @discardableResult
    public func stop() async -> RecordingReport {
        if let r = lock.withLock({ finalReport }) { return r }
        return await withCheckedContinuation { cont in
            let alreadyStopping: Bool = lock.withLock {
                if let r = finalReport {
                    cont.resume(returning: r)
                    return true
                }
                stopWaiters.append(cont)
                defer { stopping = true }
                return stopping
            }
            if alreadyStopping { return }
            guard let p = pipeline else {
                finish(RecordingReport(status: .failed, start: nil, duration: 0, device: "", deviceID: "",
                                       gaps: [], deviceChanges: [], backwardJumps: 0, error: "not started"))
                return
            }
            if let mic = microphone {
                mic.stop { p.queue.async { p.close() } }
            } else {
                p.queue.async { p.close() }
            }
        }
    }

    // MARK: - internals

    private func wire(_ p: AudioPipeline) {
        p.onLevel = { [weak self] rms, peak in
            guard let handler = self?.onEvent else { return }
            DispatchQueue.main.async { handler(.level(rms: rms, peak: peak)) }
        }
        p.onGap = { [weak self] gap in
            guard let handler = self?.onEvent else { return }
            DispatchQueue.main.async { handler(.gap(gap)) }
        }
        p.onFinish = { [weak self] report in self?.finish(report) }
    }

    private func finish(_ report: RecordingReport) {
        let (waiters, selfStopped): ([CheckedContinuation<RecordingReport, Never>], Bool) = lock.withLock {
            guard finalReport == nil else { return ([], false) }
            finalReport = report
            let w = stopWaiters
            stopWaiters = []
            return (w, !stopping)
        }
        watchdog?.cancel()
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        if let mic = microphone, selfStopped { mic.stop {} }
        waiters.forEach { $0.resume(returning: report) }
        if selfStopped, let handler = onEvent {
            DispatchQueue.main.async { handler(.stopped(report)) }
        }
    }

    /// Once a second on the pipeline queue: drain the writer, advance the timeline through silent
    /// stretches, restart a session that went quiet, enforce the maximum length, persist progress.
    private func startWatchdog(_ p: AudioPipeline, mic: MicrophoneSource, opened: Double, noAudio: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: p.queue)
        var lastProgress = monotonicNow()
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            let now = monotonicNow()
            p.pump()
            guard !p.closing else { return }
            guard let origin = p.origin else {
                if now - opened > 10 {
                    noAudio()
                    p.complete(p.report(.failed))
                }
                return
            }
            if now - origin >= p.config.maxDuration {
                Task { await self?.stop() }
            }
            if now - mic.lastBuffer > 5 {
                p.fill(until: now)
                if now - mic.lastRestart > 10 {
                    mic.lastRestart = now
                    mic.control.async { mic.restart() }
                }
            }
            if now - lastProgress >= 60 {
                lastProgress = now
                p.persistProgress()
            }
        }
        t.resume()
        watchdog = t
    }

    // MARK: - testing

    /// Runs the pipeline with a simulated microphone. Returns the report when the simulated duration ends.
    func runSynthetic(_ source: SyntheticSource, configuration: RecorderConfiguration? = nil) async -> RecordingReport {
        let p = AudioPipeline(output: output, config: configuration ?? self.configuration, realTime: source.realTime)
        pipeline = p
        wire(p)
        return await withCheckedContinuation { cont in
            lock.withLock { stopWaiters.append(cont) }
            source.run(p)
        }
    }

    /// Starts a simulated recording and returns immediately (for stop tests).
    func startSynthetic(_ source: SyntheticSource) {
        let p = AudioPipeline(output: output, config: configuration, realTime: source.realTime)
        pipeline = p
        wire(p)
        source.run(p)
    }
}
