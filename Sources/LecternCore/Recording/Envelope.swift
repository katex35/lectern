import Accelerate
import AVFoundation
import CryptoKit

/// The loudness outline of a recording, for the scrubber.
public enum Envelope {
    /// `read`, kept in `cache` so a long lecture is decoded only once. One entry per file and bar count,
    /// replaced when the file's size or date changes.
    public static func cached(_ url: URL, buckets: Int, in cache: URL) -> [Double] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = SHA256.hash(data: Data("3|\(url.standardizedFileURL.path)|\(buckets)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let file = cache.appendingPathComponent("\(key).json")
        if let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
           entry.size == size, entry.modified == modified, entry.values.count == buckets {
            return entry.values
        }
        let values = read(url, buckets: buckets)
        if !values.isEmpty, let data = try? JSONEncoder().encode(CacheEntry(size: size, modified: modified, values: values)) {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return values
    }

    private struct CacheEntry: Codable {
        let size: Int64
        let modified: Double
        let values: [Double]
    }

    /// Loudness per bucket, 0...1 between the file's quiet floor and its loudest bucket, read in one pass.
    public static func read(_ url: URL, buckets: Int) -> [Double] {
        guard buckets > 0, let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else { return [] }
        let total = Int(file.length)
        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        var position = 0
        while position < total {
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channel = buffer.floatChannelData?[0] else { break }
            var offset = 0
            while offset < frames {
                let frame = position + offset
                let bucket = min(buckets - 1, frame * buckets / total)
                // first frame of the next bucket
                let next = ((bucket + 1) * total + buckets - 1) / buckets
                let count = min(frames - offset, max(1, next - frame))
                var sum: Float = 0
                vDSP_svesq(channel + offset, 1, &sum, vDSP_Length(count))
                sums[bucket] += Double(sum)
                counts[bucket] += count
                offset += count
            }
            position += frames
        }
        // decibels, so a lecture's quieter stretches still differ from its loud ones;
        // the quietest few buckets set the floor, at most 40 dB under the loudest
        var decibels = [Double](repeating: -.infinity, count: buckets)
        for bucket in 0..<buckets where counts[bucket] > 0 && sums[bucket] > 0 {
            let meanSquare: Double = sums[bucket] / Double(counts[bucket])
            decibels[bucket] = 10 * log10(meanSquare)
        }
        guard let loudest = decibels.max(), loudest.isFinite else { return decibels.map { _ in 0 } }
        let quiet: Double = max(decibels.sorted()[decibels.count / 20], loudest - 40)
        let range = loudest - quiet
        guard range > 0.5 else { return decibels.map { _ in 1 } }
        return decibels.map { min(1, max(0, ($0 - quiet) / range)) }
    }
}
