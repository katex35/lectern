import AVFoundation
import Foundation

/// The last couple of minutes of a track, kept in a small file next to the recording so the app can
/// listen in while the recorder (another process) writes. A ring: new samples overwrite the oldest.
///
///     header (32 bytes): "LCRG", version, sample rate, capacity in frames, frames written so far,
///                        wall-clock time of frame 0
///     then `capacity` 16-bit mono samples
///
/// One writer, any number of readers, in different processes. The writer marks the count as busy
/// before it touches a sample and writes the new count when it is done. A reader takes the count,
/// the samples, then the count again: if the writer was busy at either end, or has gone around in
/// between, it reads once more.
public final class LiveAudioRing: @unchecked Sendable {
    public struct Snapshot: Sendable {
        /// 16-bit mono samples, oldest first.
        public var samples: [Int16]
        /// Index, since the start of the track, of the first sample here.
        public var firstFrame: Int
        public var sampleRate: Double
        /// Wall-clock time of frame 0 of the track.
        public var start: Date

        public var endFrame: Int { firstFrame + samples.count }
    }

    static let magic: [UInt8] = Array("LCRG".utf8)
    static let headerSize = 32
    /// Set in the count while the writer is changing samples.
    static let busy: UInt64 = 1 << 63

    public let url: URL
    public let sampleRate: Double
    public let capacity: Int
    private let handle: FileHandle
    private var written = 0
    private let lock = NSLock()

    /// Creates the file for writing. `seconds`: how much of the track is kept.
    public init(writingTo url: URL, sampleRate: Double, seconds: Double = 120, start: Date = Date()) throws {
        self.url = url
        self.sampleRate = sampleRate
        capacity = max(1, Int(sampleRate * seconds))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        var header = Data(Self.magic)
        header.append(contentsOf: Self.bytes(UInt32(1)))
        header.append(contentsOf: Self.bytes(UInt32(sampleRate)))
        header.append(contentsOf: Self.bytes(UInt32(capacity)))
        header.append(contentsOf: Self.bytes(UInt64(0)))
        header.append(contentsOf: Self.bytes(start.timeIntervalSince1970.bitPattern))
        try handle.write(contentsOf: header)
        try handle.truncate(atOffset: UInt64(Self.headerSize + capacity * 2))
    }

    static func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    /// Adds samples at the end of the track; `nil` stands for that many frames of silence.
    public func append(_ samples: UnsafePointer<Int16>?, count: Int) {
        guard count > 0 else { return }
        lock.withLock {
            // said first: the oldest samples are about to change, a reader must not trust them
            try? handle.seek(toOffset: 16)
            try? handle.write(contentsOf: Data(Self.bytes(UInt64(written) | Self.busy)))
            var done = 0
            // only what still fits the ring matters when more than a ring arrives at once
            if count > capacity {
                done = count - capacity
                written += done
            }
            while done < count {
                let position = written % capacity
                let n = min(count - done, capacity - position)
                let data: Data
                if let samples {
                    data = Data(bytes: samples + done, count: n * 2)
                } else {
                    data = Data(count: n * 2)
                }
                try? handle.seek(toOffset: UInt64(Self.headerSize + position * 2))
                try? handle.write(contentsOf: data)
                done += n
                written += n
            }
            // the count goes last: a reader never sees frames that are not in the file yet
            try? handle.seek(toOffset: 16)
            try? handle.write(contentsOf: Data(Self.bytes(UInt64(written))))
        }
    }

    public func close() {
        lock.withLock { try? handle.close() }
    }

    // MARK: reading

    struct Header {
        var sampleRate: Double
        var capacity: Int
        var written: Int
        var start: Date
        /// The writer is in the middle of adding samples.
        var busy: Bool
    }

    static func header(_ handle: FileHandle) -> Header? {
        guard (try? handle.seek(toOffset: 0)) != nil, let data = try? handle.read(upToCount: headerSize),
              data.count == headerSize, Array(data.prefix(4)) == magic else { return nil }
        func integer<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
            data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }
        guard integer(4, UInt32.self) == 1 else { return nil }
        let capacity = Int(integer(12, UInt32.self))
        guard capacity > 0 else { return nil }
        let count = integer(16, UInt64.self)
        return Header(sampleRate: Double(integer(8, UInt32.self)), capacity: capacity, written: Int(count & ~busy),
                      start: Date(timeIntervalSince1970: Double(bitPattern: integer(24, UInt64.self))), busy: count & busy != 0)
    }

    /// The frames from `from` on (or the last `seconds` when `from` is nil), as far as the ring still
    /// has them. Nil when the file is missing or not a ring.
    public static func read(_ url: URL, from: Int? = nil, last seconds: Double? = nil) -> Snapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        for attempt in 0..<4 {
            // a write takes microseconds: a moment later the ring is whole again
            if attempt > 0 { usleep(400) }
            guard let before = header(handle) else { return nil }
            if before.busy { continue }
            let oldest = max(0, before.written - before.capacity)
            var first = oldest
            if let from { first = max(oldest, from) }
            if let seconds { first = max(first, before.written - Int(seconds * before.sampleRate)) }
            first = min(first, before.written)
            let count = before.written - first
            var samples = [Int16](repeating: 0, count: count)
            var done = 0
            var failed = false
            while done < count, !failed {
                let position = (first + done) % before.capacity
                let n = min(count - done, before.capacity - position)
                guard (try? handle.seek(toOffset: UInt64(headerSize + position * 2))) != nil,
                      let data = try? handle.read(upToCount: n * 2), data.count == n * 2 else {
                    failed = true
                    break
                }
                samples.withUnsafeMutableBytes { target in
                    data.copyBytes(to: target.baseAddress!.advanced(by: done * 2).assumingMemoryBound(to: UInt8.self), count: n * 2)
                }
                done += n
            }
            guard !failed, let after = header(handle) else { return nil }
            // the writer was at work, or went past what was being read: those samples are no longer
            // what they were
            if after.busy || after.written - after.capacity > first { continue }
            return Snapshot(samples: samples, firstFrame: first, sampleRate: before.sampleRate, start: before.start)
        }
        return nil
    }
}

/// A few seconds of 16-bit mono sound as a small AAC file in memory: a tenth of the size of the raw
/// samples, so it is sent quickly on a slow line too.
public enum AudioClip {
    public static let mimeType = "audio/mp4"

    public static func m4a(_ samples: [Int16], sampleRate: Double, bitRate: Int = 32000) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-clip-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            throw RecorderError.failed("cannot prepare the clip")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let target = buffer.floatChannelData![0]
        for i in 0..<samples.count { target[i] = Float(samples[i]) / 32768 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}

/// 16-bit mono samples as a WAV file in memory.
public enum WAV {
    public static func data(_ samples: [Int16], sampleRate: Double) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) }) }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16))
        put(UInt16(1))
        put(UInt16(1))
        put(UInt32(sampleRate))
        put(UInt32(sampleRate) * 2)
        put(UInt16(2))
        put(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        put(bytes)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
