import AVFoundation
import Foundation

/// Repairs a recording whose recorder stopped without finalizing it (crash, power loss). Such a file
/// is fragmented and readable up to its last fragment; it is rewritten as a plain .m4a without
/// re-encoding. The original stays next to it until the user deletes it.
public enum RecordingRecovery {
    public struct Result: Sendable {
        public var file: URL
        /// The untouched original, kept as a hidden file beside the recording.
        public var original: URL
        public var duration: Double
    }

    public enum Failure: LocalizedError {
        case unreadable
        case exportFailed(String)
        case verificationFailed(Double, Double)

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The recording cannot be read."
            case .exportFailed(let m): return "Rewriting the recording failed: \(m)"
            case .verificationFailed(let got, let want):
                return String(format: "The repaired file is %.1f s instead of %.1f s; the original was kept.", got, want)
            }
        }
    }

    /// The hidden name the original gets after a repair.
    public static func originalURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("." + file.deletingPathExtension().lastPathComponent
                                                                  + ".unrepaired.m4a")
    }

    /// True if the file is written in fragments (it contains a `moof` box), as an interrupted recording is.
    public static func isFragmented(_ file: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? h.close() }
        var offset: UInt64 = 0
        while true {
            guard (try? h.seek(toOffset: offset)) != nil, let header = try? h.read(upToCount: 16), header.count >= 8 else {
                return false
            }
            var size = UInt64(header.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if type == "moof" { return true }
            if size == 1, header.count >= 16 {
                size = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            }
            guard size >= 8 else { return false }
            offset += size
        }
    }

    public static func repair(_ file: URL) async throws -> Result {
        let asset = AVURLAsset(url: file)
        let expected = try await asset.load(.duration).seconds
        guard expected.isFinite, expected > 0 else { throw Failure.unreadable }
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).repair.m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.exportFailed("no passthrough export for this file")
        }
        export.outputURL = temp
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            throw Failure.exportFailed(export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        }
        // the copy must decode and be as long as what the original exposes
        let repaired = try AVAudioFile(forReading: temp)
        let got = Double(repaired.length) / repaired.processingFormat.sampleRate
        guard abs(got - expected) <= max(0.5, expected * 0.01) else { throw Failure.verificationFailed(got, expected) }
        let original = originalURL(for: file)
        try? FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: file, to: original)
        try FileManager.default.moveItem(at: temp, to: file)
        return Result(file: file, original: original, duration: got)
    }
}
