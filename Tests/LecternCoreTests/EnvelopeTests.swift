import AVFoundation
import XCTest
@testable import LecternCore

final class EnvelopeTests: XCTestCase {
    /// Two seconds of silence, then two seconds of a tone: the outline is flat, then full.
    func testOutlineFollowsLoudness() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("envelope-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 16000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * 4)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) {
            samples[i] = i < Int(rate * 2) ? 0 : Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / rate))
        }
        try file.write(from: buffer)

        let outline = Envelope.read(url, buckets: 8)
        XCTAssertEqual(outline.count, 8)
        XCTAssertEqual(outline.prefix(4).max() ?? 1, 0, accuracy: 0.001)
        for value in outline.suffix(4) { XCTAssertEqual(value, 1, accuracy: 0.02) }

        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("envelopes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        XCTAssertEqual(Envelope.cached(url, buckets: 8, in: cache), outline)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 1)
        XCTAssertEqual(Envelope.cached(url, buckets: 8, in: cache), outline)
    }

    func testMissingFileGivesNothing() {
        XCTAssertEqual(Envelope.read(URL(fileURLWithPath: "/nonexistent.m4a"), buckets: 10), [])
    }
}
