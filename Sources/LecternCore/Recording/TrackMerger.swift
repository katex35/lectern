import AVFoundation
import Foundation

/// What became of the computer's audio recorded next to a microphone recording.
public struct SystemAudioReport: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Mixed into the recording.
        case mixed
        /// Recorded, but nothing was ever played: the recording is the microphone alone.
        case silent
        /// Could not be recorded or mixed in; the recording is the microphone alone.
        case failed
    }

    public var status: Status
    public var error: String?

    public init(status: Status, error: String? = nil) {
        self.status = status
        self.error = error
    }
}

/// The hidden files a meeting leaves next to `recording-HHmmss.m4a`. The recording itself is always a
/// playable file: the microphone alone until the computer's audio is mixed in, both after.
///
///     .recording-X.system.m4a       what the Mac played, not mixed in yet; gone once it is
///     .recording-X.microphone.m4a   the microphone alone, kept for a while after mixing
///     .recording-X.computer.m4a     what the Mac played, kept for a while after mixing
///     .recording-X.unmixed.m4a      a system track that could not be mixed in, kept for a while
public enum RecordingTracks {
    static func hidden(_ file: URL, _ tag: String) -> URL {
        file.deletingLastPathComponent()
            .appendingPathComponent("." + file.deletingPathExtension().lastPathComponent + ".\(tag).m4a")
    }

    /// What the Mac played while `file` was recorded, waiting to be mixed in.
    public static func system(for file: URL) -> URL { hidden(file, "system") }
    /// The same after it was mixed in, kept for a while.
    public static func computer(for file: URL) -> URL { hidden(file, "computer") }
    /// The microphone alone, kept for a while after the computer's audio was mixed into `file`.
    public static func microphone(for file: URL) -> URL { hidden(file, "microphone") }
    /// The mix while it is being written.
    static func mixing(for file: URL) -> URL { hidden(file, "mixing") }
    /// A system track that could not be mixed in, set aside so it is not tried on every launch.
    static func unmixed(for file: URL) -> URL { hidden(file, "unmixed") }

    /// The copies kept after the work on `file` is done, with the reports beside them. A system track
    /// still waiting to be mixed is not one of them: it is never thrown away for being old.
    static func kept(for file: URL) -> [URL] {
        let tracks = [microphone(for: file), computer(for: file), unmixed(for: file)]
        return tracks + tracks.map(RecordingReport.sidecar(for:))
    }

    /// Moves a track with its report. The moved files count as new, so a copy set aside today is not
    /// cleaned up as an old one tomorrow.
    static func move(_ track: URL, to target: URL) {
        let fm = FileManager.default
        for (from, to) in [(track, target), (RecordingReport.sidecar(for: track), RecordingReport.sidecar(for: target))] {
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.removeItem(at: to)
            try? fm.moveItem(at: from, to: to)
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: to.path)
        }
    }
}

/// Mixes the computer's audio into a microphone recording, on the microphone's timeline: the result is
/// exactly as long as the microphone file, so gaps and typed notes keep their place.
public enum TrackMerger {
    public struct Result: Sendable {
        public var duration: Double
        public var microphoneGain: Double
        public var systemGain: Double
        /// Nothing was ever played: nothing was written.
        public var systemSilent: Bool
    }

    public enum Failure: LocalizedError {
        case unreadable(String)
        case writeFailed(String)
        case verificationFailed(Double, Double)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let what): return "The computer's audio could not be mixed in: \(what)"
            case .writeFailed(let what): return "The mixed recording could not be written: \(what)"
            case .verificationFailed(let got, let want):
                return String(format: "The mixed recording is %.1f s instead of %.1f s; the microphone recording was kept.", got, want)
            }
        }
    }

    /// Speech level both tracks are brought to (about -22 dBFS RMS over the parts where someone speaks),
    /// so a far microphone is not lost under the other side of the call.
    static let targetLevel = 0.08
    /// A track is never turned down below, or up above, these.
    static let gainRange = 0.5...8.0
    /// Mean square below this (about -50 dBFS) is nothing at all.
    static let floor = 1e-5
    /// Frames read at a time: memory stays the same for an eight hour meeting.
    static let chunk: AVAudioFrameCount = 160_000

    /// How loud a track is where it matters.
    enum Loudness: Equatable {
        /// Nothing at all.
        case silent
        /// Background only: nobody speaks loudly enough to tell speech from the room.
        case quiet
        /// The level (RMS) of the stretches where someone speaks.
        case speech(Double)
    }

    /// A track whose loud twentieth stays below this (about -40 dBFS) is background, and left as it is:
    /// turning it up would only turn up the room.
    static let speechThreshold = 0.01

    /// Measures `file` in blocks of 50 ms. Speech is what lies within 25 dB of the loud blocks; the
    /// pauses between sentences do not count, so a track is not turned up for its silences.
    static func loudness(of file: AVAudioFile) throws -> Loudness {
        let format = file.processingFormat
        let block = max(1, Int(format.sampleRate / 20))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw Failure.unreadable("out of memory")
        }
        file.framePosition = 0
        defer { file.framePosition = 0 }
        // mean square of every block: 72,000 numbers for an hour
        var blocks: [Double] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            guard n > 0, let x = buffer.floatChannelData?[0] else { break }
            var i = 0
            while i < n {
                let end = min(i + block, n)
                var sum = 0.0
                for j in i..<end { sum += Double(x[j]) * Double(x[j]) }
                blocks.append(sum / Double(end - i))
                i = end
            }
        }
        guard let loudest = blocks.max(), loudest > floor else { return .silent }
        let sorted = blocks.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        guard loud.squareRoot() >= speechThreshold else { return .quiet }
        let cut = max(floor, loud / 316)   // 25 dB below, in power
        let speech = blocks.filter { $0 >= cut }
        return .speech((speech.reduce(0, +) / Double(speech.count)).squareRoot())
    }

    static func gain(for loudness: Loudness) -> Double {
        guard case .speech(let level) = loudness, level > 0 else { return 1 }
        return min(max(targetLevel / level, gainRange.lowerBound), gainRange.upperBound)
    }

    /// Loud sums are bent towards full scale instead of clipping.
    @inline(__always)
    static func limit(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.8 { return x }
        let y = 0.8 + 0.19 * tanh((a - 0.8) / 0.19)
        return x < 0 ? -y : y
    }

    /// Fills `buffer` with `count` frames from `file`; what the file does not have stays silent.
    static func read(_ file: AVAudioFile, into buffer: AVAudioPCMBuffer, count: AVAudioFrameCount,
                     scratch: AVAudioPCMBuffer, at offset: Int) throws {
        var done: AVAudioFrameCount = 0
        guard let out = buffer.floatChannelData?[0] else { return }
        while done < count, file.framePosition < file.length {
            try file.read(into: scratch, frameCount: count - done)
            let n = scratch.frameLength
            guard n > 0, let x = scratch.floatChannelData?[0] else { break }
            memcpy(out + offset + Int(done), x, Int(n) * MemoryLayout<Float>.size)
            done += n
        }
    }

    /// Writes the mix of `microphone` and `system` to `output`. `offset`: seconds from the first sample
    /// of the microphone to the first sample of the system track (never negative).
    @discardableResult
    public static func mix(microphone: URL, system: URL, offset: Double, to output: URL,
                           bitRate: Int = 48000) throws -> Result {
        let mic: AVAudioFile, sys: AVAudioFile
        do {
            mic = try AVAudioFile(forReading: microphone)
            sys = try AVAudioFile(forReading: system)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let format = mic.processingFormat
        let rate = format.sampleRate
        guard sys.processingFormat.sampleRate == rate, mic.length > 0 else {
            throw Failure.unreadable("the two tracks do not match")
        }
        let expected = Double(mic.length) / rate
        let systemLoudness = try loudness(of: sys)
        guard systemLoudness != .silent else {
            return Result(duration: expected, microphoneGain: 1, systemGain: 0, systemSilent: true)
        }
        let micGain = Float(gain(for: try loudness(of: mic)))
        let sysGain = Float(gain(for: systemLoudness))
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let micBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let sysBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk),
              let sysScratch = AVAudioPCMBuffer(pcmFormat: sys.processingFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk) else {
            throw Failure.unreadable("out of memory")
        }
        let lead = max(0, Int((offset * rate).rounded()))
        let total = Int(mic.length)
        try? FileManager.default.removeItem(at: output)
        do {
            let writer = try AVAudioFile(forWriting: output, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate], commonFormat: .pcmFormatFloat32, interleaved: false)
            var position = 0
            while position < total {
                let n = min(Int(chunk), total - position)
                try mic.read(into: micBuffer, frameCount: AVAudioFrameCount(n))
                let got = Int(micBuffer.frameLength)
                guard got > 0, let m = micBuffer.floatChannelData?[0], let s = sysBuffer.floatChannelData?[0],
                      let o = outBuffer.floatChannelData?[0] else { break }
                // the stretch of the system track that falls under these microphone frames
                memset(s, 0, got * MemoryLayout<Float>.size)
                let silentFirst = min(got, max(0, lead - position))
                if silentFirst < got {
                    sys.framePosition = AVAudioFramePosition(position + silentFirst - lead)
                    try read(sys, into: sysBuffer, count: AVAudioFrameCount(got - silentFirst), scratch: sysScratch,
                             at: silentFirst)
                }
                for i in 0..<got { o[i] = limit(m[i] * micGain + s[i] * sysGain) }
                outBuffer.frameLength = AVAudioFrameCount(got)
                try writer.write(from: outBuffer)
                position += got
            }
        } catch let failure as Failure {
            try? FileManager.default.removeItem(at: output)
            throw failure
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw Failure.writeFailed(error.localizedDescription)
        }
        // the mix must open and be as long as the microphone recording it replaces
        guard let written = AudioLength.seconds(of: output), abs(written - expected) <= max(0.5, expected * 0.01) else {
            let got = AudioLength.seconds(of: output) ?? 0
            try? FileManager.default.removeItem(at: output)
            throw Failure.verificationFailed(got, expected)
        }
        return Result(duration: written, microphoneGain: Double(micGain), systemGain: Double(sysGain), systemSilent: false)
    }

    /// True when the computer's audio was recorded next to `file` and is not mixed in yet.
    public static func isPending(_ file: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: file.path)
            && fm.fileExists(atPath: RecordingTracks.system(for: file).path)
            && !fm.fileExists(atPath: RecordingTracks.microphone(for: file).path)
    }

    /// A mix that replaced the recording but was interrupted before its system track was put away:
    /// the track is put away now. Without this the track would look unmixed again once the copy of
    /// the microphone is cleaned up, and be mixed in a second time.
    static func finishInterrupted(_ file: URL) {
        let fm = FileManager.default
        let system = RecordingTracks.system(for: file)
        if fm.fileExists(atPath: system.path), fm.fileExists(atPath: RecordingTracks.microphone(for: file).path) {
            RecordingTracks.move(system, to: RecordingTracks.computer(for: file))
        }
        if !isPending(file) { try? fm.removeItem(at: RecordingTracks.mixing(for: file)) }
    }

    /// Mixes the system track of `file` into it. The file is replaced in one step and the microphone
    /// alone stays next to it as a hidden file, so this can be interrupted and run again at any point.
    /// A track that cannot be mixed is set aside, so it is not tried again on every launch.
    @discardableResult
    public static func mixPending(_ file: URL) -> SystemAudioReport {
        let fm = FileManager.default
        let system = RecordingTracks.system(for: file)
        let temp = RecordingTracks.mixing(for: file)
        try? fm.removeItem(at: temp)
        func setAside() { RecordingTracks.move(system, to: RecordingTracks.unmixed(for: file)) }
        guard let micStart = (try? JSONStore.read(RecordingReport.self, from: RecordingReport.sidecar(for: file)))?.start,
              let sysStart = (try? JSONStore.read(RecordingReport.self, from: RecordingReport.sidecar(for: system)))?.start
        else {
            setAside()
            return SystemAudioReport(status: .failed, error: Failure.unreadable("its start time is unknown").localizedDescription)
        }
        do {
            let result = try mix(microphone: file, system: system, offset: max(0, sysStart.timeIntervalSince(micStart)), to: temp)
            if result.systemSilent {
                try? fm.removeItem(at: system)
                try? fm.removeItem(at: RecordingReport.sidecar(for: system))
                return SystemAudioReport(status: .silent)
            }
            _ = try fm.replaceItemAt(file, withItemAt: temp, backupItemName: RecordingTracks.microphone(for: file).lastPathComponent,
                                     options: .withoutDeletingBackupItem)
            // the recording is the mix from here on; the track that went into it is no longer waiting
            RecordingTracks.move(system, to: RecordingTracks.computer(for: file))
            return SystemAudioReport(status: .mixed)
        } catch {
            try? fm.removeItem(at: temp)
            setAside()
            return SystemAudioReport(status: .failed, error: error.localizedDescription)
        }
    }
}
