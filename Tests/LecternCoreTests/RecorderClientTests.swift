import AVFoundation
import XCTest
@testable import LecternCore

/// The helper process runs with a simulated microphone (`--simulate`), so these need no audio hardware.
final class RecorderClientTests: XCTestCase {
    var folder: URL!
    var helper: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // the test bundle sits next to the built executables
        helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("lectern-recorder")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "helper not built at \(helper.path)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func duration(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }

    func testRecordsAndStopsInItsOwnProcess() async throws {
        let url = folder.appendingPathComponent("recording.m4a")
        let client = RecorderClient(helper: helper, output: url)
        let levels = Counter()
        client.onEvent = { if case .level = $0 { levels.add() } }
        _ = try await client.start(simulate: 60)
        XCTAssertNotNil(client.pid)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let report = await client.stop()
        XCTAssertEqual(report?.status, .finished, report?.error ?? "")
        XCTAssertEqual(report?.duration ?? 0, 2.5, accuracy: 0.6)
        XCTAssertEqual(try duration(url), report?.duration ?? 0, accuracy: 0.15)
        XCTAssertFalse(RecorderClient.isAlive(client.pid!))
        XCTAssertGreaterThan(levels.value, 5)
    }

    func testKeepsRecordingWhenTheAppGoesAwayAndReattaches() async throws {
        let url = folder.appendingPathComponent("recording.m4a")
        // launch the helper like the app does, then drop its stdout as if the app had quit
        let p = Process()
        p.executableURL = helper
        p.arguments = [url.path, "--simulate", "60"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        // a slow launch (memory pressure) must not eat into the recording: wait until audio flows
        var output = Data()
        while !String(decoding: output, as: UTF8.self).contains("\"event\":\"ready\"") {
            let chunk = pipe.fileHandleForReading.availableData
            XCTAssertFalse(chunk.isEmpty, "helper ended before it was ready")
            if chunk.isEmpty { return }
            output.append(chunk)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try pipe.fileHandleForReading.close()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(p.isRunning, "helper must survive a closed stdout")

        let attached = try XCTUnwrap(RecorderClient.attach(pid: p.processIdentifier, output: url))
        let report = await attached.stop()
        XCTAssertEqual(report?.status, .finished, report?.error ?? "")
        XCTAssertEqual(report?.duration ?? 0, 3, accuracy: 0.8)
        XCTAssertEqual(try duration(url), report?.duration ?? 0, accuracy: 0.15)
        p.waitUntilExit()
    }

    func testReportsARecordingThatEndsOnItsOwn() async throws {
        let url = folder.appendingPathComponent("recording.m4a")
        let client = RecorderClient(helper: helper, output: url)
        let ended = expectation(description: "ended")
        client.onEvent = { event in
            if case .ended(let report) = event, report.status == .finished { ended.fulfill() }
        }
        _ = try await client.start(simulate: 2, gaps: [(0.5, 0.8)])
        await fulfillment(of: [ended], timeout: 10)
        let report = try XCTUnwrap(client.sidecarReport())
        // 0.8 s is below the wall-clock gap threshold: filled where it happened, as a dropped stretch
        XCTAssertEqual(report.gaps.map(\.reason), [.droppedBuffer])
        XCTAssertEqual(report.gaps.first?.duration ?? 0, 0.8, accuracy: 0.02)
        XCTAssertEqual(try duration(url), 2, accuracy: 0.15)
    }

    func testStartFailsCleanlyForAnExistingFile() async throws {
        let url = folder.appendingPathComponent("recording.m4a")
        try Data("old".utf8).write(to: url)
        let client = RecorderClient(helper: helper, output: url)
        do {
            _ = try await client.start()
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already exists"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
