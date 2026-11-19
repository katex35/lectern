import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac plays through a Core Audio process tap and hands every buffer to the
/// pipeline. macOS asks the user once for "System Audio Recording"; until that is allowed nothing
/// arrives. Buffers come only while something is playing: silence in between is not a fault, the
/// pipeline fills it by the clock. The tap is built again when the output device changes (headphones
/// connected in the middle of a call) or the audio service restarts.
///
/// Setup and teardown run on `control`; buffers arrive on the pipeline queue.
@available(macOS 14.2, *)
final class SystemAudioSource {
    let pipeline: AudioPipeline
    let control = DispatchQueue(label: "lectern.recorder.system-audio")
    // owned by the pipeline queue (the tap's callbacks and the recorder's watchdog both run there)
    var lastBuffer = monotonicNow()
    // owned by `control`
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var listener: AudioObjectPropertyListenerBlock?
    private var stopped = false
    /// Called on `control` when the tap cannot be built, and when it runs (again).
    var onProblem: (String) -> Void = { _ in }
    var onRunning: () -> Void = {}

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// What makes the tap worth building again: another output device, or coreaudiod coming back.
    private static let rebuildOn = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyServiceRestarted]

    init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        a = address(kAudioDevicePropertyDeviceUID)
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &a, 0, nil, &size, $0) }
        guard status == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    func start() {
        control.async {
            guard !self.stopped else { return }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuild() }
            for selector in Self.rebuildOn {
                var a = Self.address(selector)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, self.control, block)
            }
            self.listener = block
            self.build()
        }
    }

    /// Builds the tap again, on `control`.
    func rebuild() {
        control.async {
            guard !self.stopped else { return }
            self.teardown()
            self.build()
        }
    }

    /// Stops for good. `then` runs on `control` once nothing is captured any more.
    func stop(then: @escaping () -> Void) {
        control.async {
            if !self.stopped {
                self.stopped = true
                if let block = self.listener {
                    for selector in Self.rebuildOn {
                        var a = Self.address(selector)
                        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, self.control, block)
                    }
                    self.listener = nil
                }
                self.teardown()
            }
            then()
        }
    }

    private func closeAggregate() {
        guard aggregate != kAudioObjectUnknown else { return }
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        AudioHardwareDestroyAggregateDevice(aggregate)
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
    }

    private func teardown() {
        closeAggregate()
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private func build() {
        guard !stopped else { return }
        // every process, mixed to stereo; played to the speakers as before
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Lectern"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            teardown()
            return onProblem("the audio tap could not be created (\(status))")
        }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = Self.address(kAudioTapPropertyFormat)
        status = AudioObjectGetPropertyData(tap, &a, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd), asbd.mBytesPerFrame > 0 else {
            teardown()
            return onProblem("the audio tap has no format (\(status))")
        }
        // A tap is read through an aggregate device that holds it. The tap alone is enough: with no
        // other device inside, the only stream is the tap's, whatever the headphones or the display
        // bring along. Where the system refuses that, the output device goes in as its clock.
        status = open(tap: description.uuid.uuidString, format: format, asbd: asbd, output: nil)
        if status != noErr, let output = Self.defaultOutputUID() {
            closeAggregate()
            status = open(tap: description.uuid.uuidString, format: format, asbd: asbd, output: output)
        }
        guard status == noErr else {
            teardown()
            return onProblem("the audio tap could not be started (\(status))")
        }
        pipeline.queue.async { self.pipeline.deviceName = "System audio" }
        onRunning()
    }

    private func open(tap uid: String, format: AVAudioFormat, asbd: AudioStreamBasicDescription, output: String?) -> OSStatus {
        var device: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lectern",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: uid]],
        ]
        if let output {
            device[kAudioAggregateDeviceMainSubDeviceKey] = output
            device[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var status = AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate)
        guard status == noErr else { return status }

        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let rate = asbd.mSampleRate
        let pipeline = self.pipeline
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, pipeline.queue) { [weak self] _, input, time, _, _ in
            guard let self else { return }
            let now = monotonicNow()
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // the tap's stream comes after those of any device inside the aggregate: its buffers are the last
            guard let last = source.last, last.mData != nil else { return }
            let frames = Int(last.mDataByteSize) / bytesPerFrame
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            pcm.frameLength = AVAudioFrameCount(frames)
            let target = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            let first = source.count - target.count
            guard first >= 0 else { return }
            for i in 0..<target.count {
                guard let from = source[first + i].mData, let to = target[i].mData else { return }
                memcpy(to, from, Int(min(source[first + i].mDataByteSize, target[i].mDataByteSize)))
            }
            // When the buffer was played: its age on the host clock is carried over to the monotonic
            // clock, as the microphone does. Implausible ages fall back to the buffer's length.
            var age = Double(frames) / rate
            if time.pointee.mFlags.contains(.hostTimeValid) {
                let ticks = mach_absolute_time()
                if ticks >= time.pointee.mHostTime {
                    let measured = Double(ticks - time.pointee.mHostTime) * Self.secondsPerTick
                    if measured <= 5 { age = measured }
                }
            }
            self.lastBuffer = now
            pipeline.append(pcm, start: now - age)
        }
        guard status == noErr, let proc else { return status == noErr ? kAudioHardwareUnspecifiedError : status }
        return AudioDeviceStart(aggregate, proc)
    }
}

/// Records what the Mac plays to its own file next to a microphone recording. It never stops or fails
/// the microphone recording: a problem is reported and the meeting goes on with the microphone alone.
public final class SystemAudioRecorder: @unchecked Sendable {
    public enum Event: Sendable {
        /// Something the Mac played was heard: the other side of the call is in the recording.
        case heard
        case problem(String)
    }

    /// The tap needs macOS 14.2.
    public static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    public let output: URL
    /// Delivered on the main queue.
    public var onEvent: (@Sendable (Event) -> Void)?

    private let pipeline: AudioPipeline
    private let lock = NSLock()
    // everything below is guarded by `lock`
    private var source: AnyObject?
    private var watchdog: DispatchSourceTimer?
    private var finalReport: RecordingReport?
    private var waiters: [CheckedContinuation<RecordingReport?, Never>] = []
    private var started = false
    private var stopping = false
    private var heard = false
    private var lastProblem: String?

    public init(output: URL, configuration: RecorderConfiguration = .init(), realTime: Bool = true) {
        self.output = output
        var config = configuration
        // The tap is silent between sounds, and its buffers carry exact times: a stretch without input
        // is filled to the sample, so what is played lands where it was heard next to the microphone.
        config.gapThreshold = 0.05
        pipeline = AudioPipeline(output: output, config: config, realTime: realTime)
        pipeline.onLevel = { [weak self] _, peak in
            // about ten times a second; -50 dBFS is well above an idle output
            guard let self, peak > -50 else { return }
            let first: Bool = self.lock.withLock {
                defer { self.heard = true }
                return !self.heard
            }
            if first { self.send(.heard) }
        }
        pipeline.onFinish = { [weak self] report in self?.finished(report) }
    }

    /// The last problem reported and not overcome, if any.
    public var problem: String? { lock.withLock { lastProblem } }

    private func send(_ event: Event) {
        guard let handler = onEvent else { return }
        DispatchQueue.main.async { handler(event) }
    }

    private func report(_ message: String) {
        let first: Bool = lock.withLock {
            defer { lastProblem = message }
            return lastProblem != message
        }
        if first { send(.problem(message)) }
    }

    /// The pipeline is closed: by `stop()`, or on its own because the file could not be written.
    private func finished(_ report: RecordingReport) {
        let (waiting, timer, tap, unasked): ([CheckedContinuation<RecordingReport?, Never>], DispatchSourceTimer?, AnyObject?, Bool) = lock.withLock {
            finalReport = report
            defer {
                waiters = []
                watchdog = nil
            }
            return (waiters, watchdog, source, !stopping)
        }
        timer?.cancel()
        if unasked {
            // nobody asked for the end: the capture must not go on feeding a closed file
            self.report(report.error ?? "the computer's audio could not be written")
            if #available(macOS 14.2, *), let tap = tap as? SystemAudioSource { tap.stop {} }
        }
        let result = FileManager.default.fileExists(atPath: output.path) ? report : nil
        waiting.forEach { $0.resume(returning: result) }
    }

    /// Starts capturing. Returns at once; audio arrives after the user allowed it.
    public func start() {
        guard #available(macOS 14.2, *) else {
            report("recording the computer's audio needs macOS 14.2 or later")
            return
        }
        // one step with `stop()`: a stop that comes first leaves nothing to start
        let tap: SystemAudioSource? = lock.withLock {
            guard !started, !stopping else { return nil }
            started = true
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: RecordingReport.sidecar(for: output))
            let tap = SystemAudioSource(pipeline: pipeline)
            tap.onProblem = { [weak self] message in self?.report(message) }
            tap.onRunning = { [weak self] in self?.running() }
            source = tap
            let p = pipeline
            let t = DispatchSource.makeTimerSource(queue: p.queue)
            var lastProgress = monotonicNow()
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler {
                let now = monotonicNow()
                p.pump()
                guard !p.closing else { return }
                // nothing is playing: the file still grows with the clock, so a crash loses no time
                if now - tap.lastBuffer > 2 { p.fill(until: now) }
                if now - lastProgress >= 60 {
                    lastProgress = now
                    p.persistProgress()
                }
            }
            t.resume()
            watchdog = t
            return tap
        }
        tap?.start()
    }

    /// The tap runs (again): an earlier problem is over.
    private func running() {
        let again: Bool = lock.withLock {
            defer { lastProblem = nil }
            return lastProblem != nil && heard
        }
        if again { send(.heard) }
    }

    /// Stops and finalizes the track. Returns nil when no audio ever arrived (nothing was written).
    @discardableResult
    public func stop() async -> RecordingReport? {
        await withCheckedContinuation { cont in
            enum Next {
                case done(RecordingReport?)
                case close(AnyObject?)
            }
            let next: Next = lock.withLock {
                stopping = true
                if let r = finalReport { return .done(FileManager.default.fileExists(atPath: output.path) ? r : nil) }
                guard started else { return .done(nil) }
                waiters.append(cont)
                return .close(source)
            }
            switch next {
            case .done(let report):
                cont.resume(returning: report)
            case .close(let tap):
                let p = pipeline
                if #available(macOS 14.2, *), let tap = tap as? SystemAudioSource {
                    tap.stop { p.queue.async { p.close() } }
                } else {
                    p.queue.async { p.close() }
                }
            }
        }
    }

    // MARK: - testing

    /// Starts a simulated source instead of the tap; it ends on its own or with `stop()`.
    func startSynthetic(_ synthetic: SyntheticSource) {
        let go: Bool = lock.withLock {
            guard !started, !stopping else { return false }
            started = true
            return true
        }
        if go { synthetic.run(pipeline) }
    }

    /// A beep in every second, `beepOffset` seconds after the microphone's. For tests and demos.
    public func startSimulated(duration: Double, beepOffset: Double = 0.5, realTime: Bool = true) {
        var synthetic = SyntheticSource(duration: duration, realTime: realTime)
        synthetic.beepOffset = beepOffset
        startSynthetic(synthetic)
    }
}
