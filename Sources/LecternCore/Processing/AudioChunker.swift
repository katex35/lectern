import Accelerate
import AVFoundation

/// One piece of a recording, cut so it can be sent for transcription on its own.
public struct AudioChunk: Sendable, Equatable {
    public var url: URL
    /// Seconds into the recording where the piece starts.
    public var start: TimeInterval
    public var duration: TimeInterval
}

/// Cuts a recording into pieces of about `length` seconds, each cut placed in the quietest moment
/// near its mark so no word is split.
public enum AudioChunker {
    public static func cutPoints(of url: URL, length: TimeInterval, search: TimeInterval = 15) -> [TimeInterval] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let rate = file.processingFormat.sampleRate
        let duration = Double(file.length) / rate
        // the last piece may run a third longer rather than leave a few seconds on their own
        guard duration > length * 4 / 3 else { return [] }
        // each piece stays between two thirds and four thirds of `length`, so every cut moves forward
        let reach = min(search, length / 3)
        var points: [TimeInterval] = []
        var mark = length
        while mark < duration - length / 3 {
            let point = quietest(in: file, from: mark - reach, to: min(mark + reach, duration - length / 3)) ?? mark
            points.append(point)
            mark = point + length
        }
        return points
    }

    /// The middle of the quietest stretch between `start` and `end`, measured in tenths of a second;
    /// a longer pause counts as one stretch, so the cut lands in its middle.
    static func quietest(in file: AVAudioFile, from start: TimeInterval, to end: TimeInterval) -> TimeInterval? {
        let rate = file.processingFormat.sampleRate
        let from = max(0, Int64(start * rate))
        let to = min(file.length, Int64(end * rate))
        guard to > from, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(to - from))
        else { return nil }
        file.framePosition = from
        guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(to - from))) != nil,
              let channel = buffer.floatChannelData?[0] else { return nil }
        let window = max(1, Int(rate / 10))
        let step = max(1, window / 2)
        let frames = Int(buffer.frameLength)
        var energies: [Float] = []
        var offset = 0
        while offset + window <= frames {
            var energy: Float = 0
            vDSP_svesq(channel + offset, 1, &energy, vDSP_Length(window))
            energies.append(energy)
            offset += step
        }
        guard let lowest = energies.min(), let first = energies.firstIndex(of: lowest) else { return nil }
        // windows within a few percent of the quietest belong to the same pause
        let tolerance = max(lowest * 1.05, lowest + 1e-6)
        var last = first
        while last + 1 < energies.count, energies[last + 1] <= tolerance { last += 1 }
        let middle = Double((first + last) * step) / 2 + Double(window) / 2
        return (Double(from) + middle) / rate
    }

    /// Writes the pieces as .m4a files into `folder` without re-encoding; a piece `needed` turns down
    /// (its text is already there) is listed but not written.
    public static func split(_ url: URL, length: TimeInterval, into folder: URL,
                             needed: (URL) -> Bool = { _ in true }) async throws -> [AudioChunk] {
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, total > 0 else { return [] }
        let bounds = [0] + cutPoints(of: url, length: length) + [total]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var chunks: [AudioChunk] = []
        for index in 0..<(bounds.count - 1) {
            let start = bounds[index], end = bounds[index + 1]
            let target = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(index).m4a")
            if needed(target), !FileManager.default.fileExists(atPath: target.path) {
                try await export(asset, from: start, to: end, into: target)
            }
            chunks.append(AudioChunk(url: target, start: start, duration: end - start))
        }
        return chunks
    }

    private static func export(_ asset: AVURLAsset, from start: TimeInterval, to end: TimeInterval, into target: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ChunkError.cannotExport
        }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000),
                                        end: CMTime(seconds: end, preferredTimescale: 1000))
        // written next to the target and moved, so a half-written piece is never taken for a finished one
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent)")
        try? FileManager.default.removeItem(at: partial)
        if #available(macOS 15, *) {
            try await session.export(to: partial, as: .m4a)
        } else {
            session.outputURL = partial
            session.outputFileType = .m4a
            await session.export()
            if let error = session.error { throw error }
            guard session.status == .completed else { throw ChunkError.cannotExport }
        }
        try FileManager.default.moveItem(at: partial, to: target)
    }

    public enum ChunkError: Error, LocalizedError {
        case cannotExport

        public var errorDescription: String? { "The recording could not be cut into pieces" }
    }
}
