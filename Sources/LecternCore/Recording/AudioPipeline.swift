import AVFoundation
import Foundation

/// Seconds on a clock that keeps running during system sleep and ignores clock changes.
func monotonicNow() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 }

public struct RecorderConfiguration: Sendable {
    public var sampleRate: Double = 16000
    public var bitRate: Int = 48000
    /// The file is written in fragments this long: after a crash it opens up to the last fragment.
    public var fragmentInterval: Double = 5
    /// Audio held in memory while the writer lags; beyond this it is dropped and reported.
    public var queueLimitSeconds: Double = 300
    /// How long stopping waits for the writer to take the queued audio.
    public var drainTimeout: Double = 20
    /// Missing input longer than this (by the wall clock) becomes a reported gap.
    public var gapThreshold: Double = 1.0
    public var maxDuration: Double = 4 * 3600

    public init() {}
}

/// What happened during a recording. Written next to the file while recording (for crash recovery)
/// and returned when it stops.
public struct RecordingReport: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording
        case finished
        case failed
    }

    public var status: Status
    /// Wall-clock time of the first sample.
    public var start: Date?
    public var duration: Double
    public var device: String
    public var deviceID: String
    public var gaps: [RecordingGap]
    public var deviceChanges: [DeviceChange]
    /// Device timestamps that went backwards (overlapping buffers); forward jumps are gaps instead.
    public var backwardJumps: Int
    public var error: String?

    public var silentSeconds: Double { gaps.reduce(0) { $0 + $1.duration } }

    /// Where the recorder keeps the report while it writes `file`.
    public static func sidecar(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".recording.json")
    }
}

/// Converts every incoming buffer to 16 kHz mono, keeps the file's timeline equal to wall-clock time
/// (missing input becomes silence) and feeds the AAC writer in order. All state lives on `queue`,
/// which is what makes handing it to other threads safe.
final class AudioPipeline: @unchecked Sendable {
    enum Item {
        case audio(AVAudioPCMBuffer)
        case silence(Int)
    }

    // release temporaries after every work item: the queue lives for hours
    let queue = DispatchQueue(label: "lectern.recorder.pipeline", autoreleaseFrequency: .workItem)
    let output: URL
    let config: RecorderConfiguration
    let realTime: Bool
    let rate: Double
    let target: AVAudioFormat
    let silenceChunk: Int
    lazy var silent: AVAudioPCMBuffer = {
        let b = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(silenceChunk))!
        b.frameLength = b.frameCapacity
        memset(b.int16ChannelData![0], 0, silenceChunk * 2)
        return b
    }()

    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    var converter: AVAudioConverter?

    var items: [Item] = []
    var head = 0
    var queuedAudio = 0          // queued audio frames (silence excluded)
    let queueLimit: Int
    var position = 0             // frames entered into the queue: position in the file
    var written = 0              // frames handed to the writer
    var origin: Double?          // monotonic time of the first sample
    var startDate: Date?         // wall-clock time of the first sample, taken once: clock changes do not move it
    var gaps: [RecordingGap] = []
    var deviceChanges: [DeviceChange] = []
    var deviceName = ""
    var deviceID = ""
    var error: String?
    var backwardJumps = 0
    var closing = false
    var finished = false

    // level meter: accumulated over ~0.1 s of audio
    var levelSquares = 0.0
    var levelPeak: Int16 = 0
    var levelFrames = 0

    /// Wall clock for gap detection; the synthetic source replaces it.
    var now: () -> Double = monotonicNow
    /// Test hook: pretend the writer is not ready.
    var stalled: (Double) -> Bool = { _ in false }
    var onReady: (RecordingReport) -> Void = { _ in }
    var onFinish: (RecordingReport) -> Void = { _ in }
    var onGap: (RecordingGap) -> Void = { _ in }
    var onLevel: (_ rms: Float, _ peak: Float) -> Void = { _, _ in }

    init(output: URL, config: RecorderConfiguration, realTime: Bool) {
        self.output = output
        self.config = config
        self.realTime = realTime
        self.rate = config.sampleRate
        self.target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: config.sampleRate, channels: 1,
                                    interleaved: true)!
        self.silenceChunk = Int(config.sampleRate)
        self.queueLimit = Int(config.queueLimitSeconds * config.sampleRate)
    }

    var duration: Double { Double(position) / rate }

    /// The writer is created when the first audio arrives: if none ever does, no file is left behind.
    func makeWriter() -> Bool {
        do {
            let w = try AVAssetWriter(outputURL: output, fileType: .m4a)
            w.movieFragmentInterval = CMTime(seconds: config.fragmentInterval, preferredTimescale: 600)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: config.bitRate])
            i.expectsMediaDataInRealTime = realTime
            guard w.canAdd(i) else {
                error = "cannot add audio input to writer"
                return false
            }
            w.add(i)
            guard w.startWriting() else {
                error = "cannot open file: \(w.error?.localizedDescription ?? "unknown error")"
                return false
            }
            w.startSession(atSourceTime: .zero)
            writer = w
            input = i
            return true
        } catch {
            self.error = "cannot open file: \(error.localizedDescription)"
            return false
        }
    }

    /// A buffer from the source. `start`: monotonic time of its first sample. `discontinuity`: time the
    /// source itself says was skipped before this buffer (a forward jump in device timestamps).
    func append(_ pcm: AVAudioPCMBuffer, start: Double, discontinuity: Double = 0) {
        guard !closing, error == nil else { return }
        if origin == nil {
            guard makeWriter() else { return fail() }
            origin = start
            startDate = Date().addingTimeInterval(-(now() - start))
            onReady(report(.recording))
        } else if discontinuity > 0.002 && discontinuity <= config.gapThreshold {
            // a short skip is filled where it happened; the wall-clock check below only
            // catches longer ones (it has to tolerate callback jitter)
            insertGap(Int((discontinuity * rate).rounded()), .droppedBuffer)
        }
        let missing = Int(((start - origin!) * rate).rounded()) - position
        if Double(missing) > config.gapThreshold * rate { insertGap(missing, .noInput) }
        guard let converted = convert(pcm) else {
            // a buffer that cannot be converted still took its time: keep the timeline and report it
            insertGap(Int((Double(pcm.frameLength) * rate / pcm.format.sampleRate).rounded()), .droppedBuffer)
            pump()
            return
        }
        guard converted.frameLength > 0 else { return }
        let n = Int(converted.frameLength)
        measure(converted)
        if queuedAudio + n > queueLimit {
            // the writer has not taken audio for minutes: keep memory bounded, count this as lost
            insertGap(n, .writerStalled)
        } else {
            items.append(.audio(converted))
            queuedAudio += n
            position += n
        }
        pump()
    }

    /// No input for a while: advance the timeline with silence up to now, so the file keeps growing
    /// and the gap is already on disk if the process dies.
    func fill(until time: Double) {
        guard let origin, !closing, error == nil else { return }
        let missing = Int(((time - origin) * rate).rounded()) - position
        if Double(missing) > config.gapThreshold * rate {
            insertGap(missing, .noInput)
            pump()
        }
    }

    func insertGap(_ frames: Int, _ reason: RecordingGap.Reason) {
        let start = duration, length = Double(frames) / rate
        if let last = gaps.last, last.reason == reason, abs(last.start + last.duration - start) < 0.01 {
            gaps[gaps.count - 1].duration += length
        } else {
            let gap = RecordingGap(start: start, duration: length, reason: reason)
            gaps.append(gap)
            onGap(gap)
            persistProgress()
        }
        if head < items.count, case .silence(let m) = items[items.count - 1] {
            items[items.count - 1] = .silence(m + frames)
        } else {
            items.append(.silence(frames))
        }
        position += frames
    }

    func noteDeviceChange(_ name: String) {
        guard origin != nil else { return }
        deviceChanges.append(DeviceChange(time: duration, device: name))
        persistProgress()
    }

    /// Report written next to the file while recording: gaps and device changes survive a crash.
    func persistProgress() {
        guard origin != nil, !closing else { return }
        writeSidecar(report(.recording))
    }

    func writeSidecar(_ r: RecordingReport) {
        try? JSONStore.write(r, to: RecordingReport.sidecar(for: output))
    }

    func measure(_ b: AVAudioPCMBuffer) {
        let n = Int(b.frameLength)
        let p = b.int16ChannelData![0]
        for i in 0..<n {
            let v = p[i]
            levelSquares += Double(v) * Double(v)
            let a = v == Int16.min ? Int16.max : abs(v)
            if a > levelPeak { levelPeak = a }
        }
        levelFrames += n
        if levelFrames >= Int(rate / 10) {
            let rms = sqrt(levelSquares / Double(levelFrames)) / 32768
            let peak = Double(levelPeak) / 32768
            onLevel(Float(20 * log10(max(rms, 1e-6))), Float(20 * log10(max(peak, 1e-6))))
            levelSquares = 0
            levelPeak = 0
            levelFrames = 0
        }
    }

    func convert(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter!.inputFormat != pcm.format {
            if let old = converter { flush(old) }
            guard let c = AVAudioConverter(from: pcm.format, to: target) else { return nil }
            c.downmix = true
            converter = c
        }
        return run(converter!, pcm)
    }

    func run(_ c: AVAudioConverter, _ pcm: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        let ratio = rate / c.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm?.frameLength ?? 0) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var given = false
        var err: NSError?
        let status = c.convert(to: out, error: &err) { _, s in
            if given || pcm == nil {
                s.pointee = pcm == nil ? .endOfStream : .noDataNow
                return nil
            }
            given = true
            s.pointee = .haveData
            return pcm
        }
        return status == .error ? nil : out
    }

    /// Queues the samples still held inside the converter (on format change and when closing).
    func flush(_ c: AVAudioConverter) {
        guard let rest = run(c, nil), rest.frameLength > 0 else { return }
        let n = Int(rest.frameLength)
        if queuedAudio + n > queueLimit {
            insertGap(n, .writerStalled)
        } else {
            items.append(.audio(rest))
            queuedAudio += n
            position += n
        }
    }

    func sampleBuffer(_ b: AVAudioPCMBuffer) -> CMSampleBuffer? {
        var sb: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate))
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: target.formatDescription, sampleCount: CMItemCount(b.frameLength),
                presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr,
              let sb,
              CMSampleBufferSetDataBufferFromAudioBufferList(
                sb, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: b.audioBufferList) == noErr
        else { return nil }
        return sb
    }

    /// Hands queued audio to the writer, in order, while it accepts more.
    func pump() {
        guard error == nil, let input, let writer, !stalled(now()) else { return }
        if writer.status == .failed { return writerFailed() }
        while head < items.count, input.isReadyForMoreMediaData {
            let buffer: AVAudioPCMBuffer
            switch items[head] {
            case .audio(let b):
                buffer = b
                queuedAudio -= Int(b.frameLength)
                head += 1
            case .silence(let n):
                let m = min(n, silenceChunk)
                silent.frameLength = AVAudioFrameCount(m)
                buffer = silent
                if n > m { items[head] = .silence(n - m) } else { head += 1 }
            }
            guard let sb = sampleBuffer(buffer) else {
                error = "cannot create sample buffer"
                return fail()
            }
            if !input.append(sb) { return writerFailed() }
            written += Int(buffer.frameLength)
        }
        if head > 4096 && head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
    }

    func writerFailed() {
        error = "write failed: \(writer?.error?.localizedDescription ?? "writer refused audio")"
        fail()
    }

    func report(_ status: RecordingReport.Status) -> RecordingReport {
        RecordingReport(status: status, start: startDate, duration: duration, device: deviceName,
                               deviceID: deviceID, gaps: gaps, deviceChanges: deviceChanges,
                               backwardJumps: backwardJumps, error: error)
    }

    func complete(_ r: RecordingReport) {
        guard !finished else { return }
        finished = true
        if writer != nil { writeSidecar(r) }
        onFinish(r)
    }

    func fail() {
        closing = true
        complete(report(.failed))
    }

    /// Stopping: fill the trailing gap, drain the queue, finalize the file. Runs once, on `queue`.
    func close() {
        guard !closing else { return }
        closing = true
        guard let origin, writer != nil else {
            if error == nil { error = "no audio arrived from the microphone" }
            complete(report(.failed))
            return
        }
        if let c = converter { flush(c) }
        let missing = Int(((now() - origin) * rate).rounded()) - position
        if Double(missing) > config.gapThreshold * rate { insertGap(missing, .noInput) }
        drain(deadline: monotonicNow() + config.drainTimeout)
    }

    func drain(deadline: Double) {
        pump()
        if finished { return }
        if head < items.count && monotonicNow() < deadline {
            queue.asyncAfter(deadline: .now() + 0.02) { self.drain(deadline: deadline) }
            return
        }
        if head < items.count {
            let rest = items[head...].reduce(0) { total, item in
                switch item {
                case .audio(let b): return total + Int(b.frameLength)
                case .silence(let n): return total + n
                }
            }
            position -= rest
            error = String(format: "writer did not drain, last %.1f s not written", Double(rest) / rate)
            // gaps inside the unwritten tail are not in the file
            let end = duration
            gaps = gaps.compactMap { g in
                guard g.start < end else { return nil }
                var c = g
                c.duration = min(g.duration, end - g.start)
                return c
            }
        }
        input!.markAsFinished()
        writer!.finishWriting {
            self.queue.async {
                if self.writer!.status != .completed {
                    self.error = "cannot finalize file: \(self.writer!.error?.localizedDescription ?? "")"
                }
                self.complete(self.report(self.error == nil ? .finished : .failed))
            }
        }
        // finishing must not hang Stop forever; the fragments already on disk stay recoverable
        queue.asyncAfter(deadline: .now() + config.drainTimeout + 10) {
            guard !self.finished else { return }
            self.error = "finalizing the file timed out; it can be recovered up to its last fragment"
            self.complete(self.report(.failed))
        }
    }
}
