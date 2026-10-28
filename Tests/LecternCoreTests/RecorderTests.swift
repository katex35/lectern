import AVFoundation
import XCTest
@testable import LecternCore

/// The recorder runs against a simulated microphone that beeps at the start of every second.
/// Beeps on whole seconds in the file prove the timeline stayed equal to wall-clock time.
final class RecorderTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func record(_ source: SyntheticSource, configure: (inout RecorderConfiguration) -> Void = { _ in })
        async -> (URL, RecordingReport) {
        var config = RecorderConfiguration()
        configure(&config)
        let url = folder.appendingPathComponent("recording.m4a")
        let report = await Recorder(output: url, configuration: config).runSynthetic(source)
        return (url, report)
    }

    /// Start times of beeps (first loud sample after at least 0.3 s of quiet), decoded with AVFoundation.
    func beepOnsets(_ url: URL) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let x = buffer.floatChannelData![0]
        var onsets: [Double] = []
        var quiet = 0
        for i in 0..<Int(buffer.frameLength) {
            if abs(x[i]) > 0.05 {
                if quiet > Int(0.3 * format.sampleRate) { onsets.append(Double(i) / format.sampleRate) }
                quiet = 0
            } else {
                quiet += 1
            }
        }
        return onsets
    }

    func wholeSeconds(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Set<Int> {
        let onsets = try beepOnsets(url)
        for t in onsets {
            XCTAssertEqual(t, t.rounded(), accuracy: 0.01, "beep off the second: \(onsets)", file: file, line: line)
        }
        return Set(onsets.map { Int($0.rounded()) })
    }

    func decodedDuration(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }

    func testGapBecomesSilenceAndWriterStallInventsNothing() async throws {
        let (url, r) = await record(SyntheticSource(duration: 30, gaps: [(10.5, 5)], stalls: [(20, 3)]))
        XCTAssertEqual(r.status, .finished, r.error ?? "")
        XCTAssertEqual(r.duration, 30, accuracy: 0.05)
        XCTAssertEqual(r.gaps.count, 1)
        XCTAssertEqual(r.gaps[0].reason, .noInput)
        XCTAssertEqual(r.gaps[0].start, 10.5, accuracy: 0.02)
        XCTAssertEqual(r.gaps[0].duration, 5, accuracy: 0.02)
        let seconds = try wholeSeconds(url)
        XCTAssertTrue(Set(1...10).union(16...29).isSubset(of: seconds), "\(seconds.sorted())")
        XCTAssertTrue(Set(11...15).isDisjoint(with: seconds))
        XCTAssertEqual(try decodedDuration(url), 30, accuracy: 0.1)
    }

    func testShortDropIsFilledWhereItHappened() async throws {
        let (url, r) = await record(SyntheticSource(duration: 30, gaps: [(10.2, 0.5), (20.3, 0.3)]))
        XCTAssertEqual(r.gaps.map(\.reason), [.droppedBuffer, .droppedBuffer])
        XCTAssertEqual(r.gaps[0].start, 10.2, accuracy: 0.02)
        XCTAssertEqual(r.gaps[0].duration, 0.5, accuracy: 0.02)
        XCTAssertEqual(r.duration, 30, accuracy: 0.05)
        XCTAssertTrue(Set(1...29).isSubset(of: try wholeSeconds(url)))
    }

    func testQueueOverflowIsReportedAndTimelineHolds() async throws {
        let (url, r) = await record(SyntheticSource(duration: 30, stalls: [(10, 8)])) { $0.queueLimitSeconds = 3 }
        XCTAssertEqual(r.gaps.map(\.reason), [.writerStalled])
        // up to 0.5 s may already be queued when the stall begins
        XCTAssertGreaterThanOrEqual(r.gaps[0].duration, 4.95)
        XCTAssertLessThanOrEqual(r.gaps[0].duration, 5.6)
        XCTAssertEqual(r.duration, 30, accuracy: 0.05)
        let seconds = try wholeSeconds(url)
        XCTAssertTrue(Set(1...12).union(19...29).isSubset(of: seconds), "\(seconds.sorted())")
        XCTAssertTrue(Set(14...17).isDisjoint(with: seconds))
    }

    func testUnwrittenTailOnStopIsAFailure() async throws {
        let (url, r) = await record(SyntheticSource(duration: 30, gaps: [(25, 2)], stalls: [(20, 100)])) {
            $0.drainTimeout = 1
        }
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(r.error?.contains("not written") == true, r.error ?? "")
        XCTAssertGreaterThanOrEqual(r.duration, 19.4)
        XCTAssertLessThanOrEqual(r.duration, 20.05)
        XCTAssertEqual(r.gaps, [])  // the gap at 25 s is in the unwritten part
        XCTAssertEqual(try decodedDuration(url), r.duration, accuracy: 0.15)
    }

    func testLongRecording() async throws {
        let (url, r) = await record(SyntheticSource(duration: 900, gaps: [(400, 120)]))
        XCTAssertEqual(r.status, .finished)
        XCTAssertEqual(r.duration, 900, accuracy: 0.1)
        XCTAssertEqual(r.gaps.first?.duration ?? 0, 120, accuracy: 0.05)
        XCTAssertEqual(try decodedDuration(url), 900, accuracy: 0.2)
    }

    func testStopFinalizesAndLevelsArrive() async throws {
        let url = folder.appendingPathComponent("recording.m4a")
        let recorder = Recorder(output: url)
        let peaks = Peaks()
        recorder.onEvent = { event in
            if case .level(_, let peak) = event { peaks.add(peak) }
        }
        recorder.startSynthetic(SyntheticSource(duration: 60, realTime: true))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let first = await recorder.stop()
        let second = await recorder.stop()
        XCTAssertEqual(first.status, .finished, first.error ?? "")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.duration, 2, accuracy: 0.5)
        XCTAssertEqual(try decodedDuration(url), first.duration, accuracy: 0.15)
        // the beep has amplitude 0.5: about -6 dBFS
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(peaks.max, -6, accuracy: 1.5)
        let sidecar = try JSONStore.read(RecordingReport.self, from: RecordingReport.sidecar(for: url))
        XCTAssertEqual(sidecar.status, .finished)
    }

    func testCrashLeavesAPlayableFileAndAProgressReport() async throws {
        let url = folder.appendingPathComponent("recording.m4a")
        let recorder = Recorder(output: url, configuration: {
            var c = RecorderConfiguration()
            c.fragmentInterval = 1
            return c
        }())
        recorder.startSynthetic(SyntheticSource(duration: 60, gaps: [(1.5, 1.5)], realTime: true))
        try await Task.sleep(nanoseconds: 4_500_000_000)
        // simulate a crash: copy the file as it is on disk right now
        let copy = folder.appendingPathComponent("crashed.m4a")
        try FileManager.default.copyItem(at: url, to: copy)
        let progress = try JSONStore.read(RecordingReport.self, from: RecordingReport.sidecar(for: url))
        await recorder.stop()
        XCTAssertEqual(progress.status, .recording)
        XCTAssertEqual(progress.gaps.count, 1, "gap was persisted while recording")
        XCTAssertGreaterThan(try decodedDuration(copy), 1.9)
    }

    func testNeverOverwritesARecording() async throws {
        let url = folder.appendingPathComponent("recording.m4a")
        try Data("old".utf8).write(to: url)
        do {
            _ = try await Recorder(output: url).start()
            XCTFail("expected fileExists")
        } catch let e as RecorderError {
            XCTAssertEqual(e, .fileExists(url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
    }

    func testInputFileSource() async throws {
        // a non-repeating tone pattern stands in for speech
        let input = folder.appendingPathComponent("input.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let file = try AVAudioFile(forWriting: input, settings: format.settings)
        let n = 22050 * 5
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let t = Double(i) / 22050
            b.floatChannelData![0][i] = Float(0.3 * sin(2 * .pi * 600 * t) * (sin(1.3 * t * t) > 0 ? 1 : 0))
        }
        try file.write(from: b)
        let reading = try AVAudioFile(forReading: input)
        let (url, r) = await record(SyntheticSource(duration: 5, inputFile: reading))
        XCTAssertEqual(r.status, .finished)
        XCTAssertEqual(try decodedDuration(url), 5, accuracy: 0.1)
    }
}

final class Peaks: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = -200
    func add(_ v: Float) { lock.lock(); value = Swift.max(value, v); lock.unlock() }
    var max: Float { lock.lock(); defer { lock.unlock() }; return value }
}
