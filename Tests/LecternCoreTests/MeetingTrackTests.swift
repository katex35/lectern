import AVFoundation
import XCTest
@testable import LecternCore

/// A meeting is two tracks: the microphone and what the Mac played. Both are made here with the
/// simulated source, which beeps once a second; the second track beeps a part of a second later, so
/// the mix shows where each track landed.
final class MeetingTrackTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-tracks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    func track(_ url: URL, duration: Double, beepOffset: Double = 0, amplitude: Double = 0.5) async -> RecordingReport {
        var source = SyntheticSource(duration: duration)
        source.beepOffset = beepOffset
        source.amplitude = amplitude
        return await Recorder(output: url).runSynthetic(source)
    }

    /// Start times of beeps: the first loud sample after at least 0.1 s of quiet.
    func onsets(_ url: URL, threshold: Float = 0.03) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let x = buffer.floatChannelData![0]
        var found: [Double] = []
        var quiet = Int(format.sampleRate)
        for i in 0..<Int(buffer.frameLength) {
            if abs(x[i]) > threshold {
                if quiet > Int(0.1 * format.sampleRate) { found.append(Double(i) / format.sampleRate) }
                quiet = 0
            } else {
                quiet += 1
            }
        }
        return found
    }

    func assertBeeps(_ url: URL, at expected: [Double], accuracy: Double = 0.03, file: StaticString = #filePath,
                     line: UInt = #line) throws {
        let found = try onsets(url)
        XCTAssertEqual(found.count, expected.count, "beeps at \(found), expected \(expected)", file: file, line: line)
        for (got, want) in zip(found, expected) {
            XCTAssertEqual(got, want, accuracy: accuracy, "beeps at \(found), expected \(expected)", file: file, line: line)
        }
    }

    func seconds(_ url: URL) throws -> Double {
        try XCTUnwrap(AudioLength.seconds(of: url))
    }

    /// Makes the system track of `file` start `offset` seconds after it, as its report says.
    func place(systemTrackOf file: URL, after offset: Double) throws {
        let micStart = try XCTUnwrap(JSONStore.read(RecordingReport.self, from: RecordingReport.sidecar(for: file)).start)
        let sidecar = RecordingReport.sidecar(for: RecordingTracks.system(for: file))
        var report = try JSONStore.read(RecordingReport.self, from: sidecar)
        report.start = micStart.addingTimeInterval(offset)
        try JSONStore.write(report, to: sidecar)
    }

    func testMixPutsBothTracksOnTheMicrophoneTimeline() async throws {
        let mic = folder.appendingPathComponent("mic.m4a"), system = folder.appendingPathComponent("system.m4a")
        await track(mic, duration: 5.5)
        await track(system, duration: 4, beepOffset: 0.5)
        let out = folder.appendingPathComponent("mix.m4a")
        let result = try TrackMerger.mix(microphone: mic, system: system, offset: 1.25, to: out)
        XCTAssertFalse(result.systemSilent)
        // the microphone on whole seconds, the computer 1.25 s later and half a second into its own seconds
        try assertBeeps(out, at: [0, 1, 1.75, 2, 2.75, 3, 3.75, 4, 4.75, 5])
        XCTAssertEqual(try seconds(out), try seconds(mic), accuracy: 0.1)
    }

    func testAFarVoiceIsBroughtUpAndALoudOneDown() async throws {
        let mic = folder.appendingPathComponent("mic.m4a"), system = folder.appendingPathComponent("system.m4a")
        await track(mic, duration: 2.8)
        await track(system, duration: 2.8, beepOffset: 0.5, amplitude: 0.02)
        let out = folder.appendingPathComponent("mix.m4a")
        let result = try TrackMerger.mix(microphone: mic, system: system, offset: 0, to: out)
        XCTAssertGreaterThan(result.systemGain, 4)
        XCTAssertLessThanOrEqual(result.systemGain, TrackMerger.gainRange.upperBound)
        XCTAssertLessThan(result.microphoneGain, 1)
        try assertBeeps(out, at: [0, 0.5, 1, 1.5, 2, 2.5], accuracy: 0.03)
        // the two voices end up closer than the 28 dB they started apart
        XCTAssertEqual(try onsets(out, threshold: 0.2).count, 3)
        XCTAssertEqual(try onsets(out, threshold: 0.07).count, 6)
    }

    func testBackgroundIsNotTurnedUp() async throws {
        let mic = folder.appendingPathComponent("mic.m4a"), system = folder.appendingPathComponent("system.m4a")
        // a microphone that only hears the room, and a call at normal level
        await track(mic, duration: 2.8, amplitude: 0.006)
        await track(system, duration: 2.8, beepOffset: 0.5, amplitude: 0.1)
        let result = try TrackMerger.mix(microphone: mic, system: system, offset: 0, to: folder.appendingPathComponent("mix.m4a"))
        XCTAssertEqual(result.microphoneGain, 1)
        XCTAssertGreaterThan(result.systemGain, 1)
    }

    func testASilentComputerLeavesTheRecordingAsItWas() async throws {
        let file = folder.appendingPathComponent("recording-100000.m4a")
        await track(file, duration: 2)
        await track(RecordingTracks.system(for: file), duration: 2, amplitude: 0)
        let before = try Data(contentsOf: file)
        XCTAssertTrue(TrackMerger.isPending(file))
        XCTAssertEqual(TrackMerger.mixPending(file).status, .silent)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(TrackMerger.isPending(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingTracks.system(for: file).path))
    }

    func testMixingReplacesTheRecordingAndKeepsTheMicrophoneAlone() async throws {
        let file = folder.appendingPathComponent("recording-100000.m4a")
        await track(file, duration: 4)
        await track(RecordingTracks.system(for: file), duration: 3, beepOffset: 0.25)
        try place(systemTrackOf: file, after: 0.5)
        let microphoneAlone = try Data(contentsOf: file)

        XCTAssertTrue(TrackMerger.isPending(file))
        XCTAssertEqual(TrackMerger.mixPending(file).status, .mixed)
        XCTAssertFalse(TrackMerger.isPending(file), "a second pass must find nothing to do")
        try assertBeeps(file, at: [0, 0.75, 1, 1.75, 2, 2.75, 3])
        XCTAssertEqual(try Data(contentsOf: RecordingTracks.microphone(for: file)), microphoneAlone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingTracks.mixing(for: file).path))
        // the track that went in is put away under another name: it can never be mixed in twice
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingTracks.system(for: file).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingTracks.computer(for: file).path))
        try FileManager.default.removeItem(at: RecordingTracks.microphone(for: file))
        XCTAssertFalse(TrackMerger.isPending(file), "losing the copy of the microphone must not make it pending again")
    }

    func testAMixInterruptedBeforeItsTrackWasPutAwayIsNotMixedTwice() async throws {
        let file = folder.appendingPathComponent("recording-100000.m4a")
        await track(file, duration: 4)
        await track(RecordingTracks.system(for: file), duration: 3, beepOffset: 0.25)
        try place(systemTrackOf: file, after: 0.5)
        XCTAssertEqual(TrackMerger.mixPending(file).status, .mixed)
        // as if the process had died right after the recording was replaced
        try FileManager.default.moveItem(at: RecordingTracks.computer(for: file), to: RecordingTracks.system(for: file))
        try Data("left over".utf8).write(to: RecordingTracks.mixing(for: file))
        let mixed = try Data(contentsOf: file)

        TrackMerger.finishInterrupted(file)
        XCTAssertFalse(TrackMerger.isPending(file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingTracks.computer(for: file).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingTracks.mixing(for: file).path))
        XCTAssertEqual(try Data(contentsOf: file), mixed)
    }

    func testATrackThatCannotBeMixedIsSetAsideAndTheRecordingKept() async throws {
        let file = folder.appendingPathComponent("recording-100000.m4a")
        await track(file, duration: 2)
        let before = try Data(contentsOf: file)
        try Data("not audio".utf8).write(to: RecordingTracks.system(for: file))
        let report = TrackMerger.mixPending(file)
        XCTAssertEqual(report.status, .failed)
        XCTAssertNotNil(report.error)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(TrackMerger.isPending(file), "a broken track must not be tried again on every launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingTracks.unmixed(for: file).path))
    }

    func testAnOldTrackThatFailsToMixIsKeptForItsOwnWeek() async throws {
        let library = Library(root: folder)
        var session = try library.newMeeting(title: "Old", date: Date())
        let file = library.folder(of: session).appendingPathComponent("recording-100000.m4a")
        await track(file, duration: 2)
        let system = RecordingTracks.system(for: file)
        try Data("not audio".utf8).write(to: system)
        // recorded two weeks ago, never mixed
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-14 * 86_400)], ofItemAtPath: system.path)
        session.recordings = [RecordingInfo(file: file.lastPathComponent, start: Date(), duration: 2)]
        try library.save(session)

        let changed = await library.recoverRecordings()
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(library.reload(session)?.recordings.first?.systemAudio?.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingTracks.unmixed(for: file).path),
                      "the only copy of the other side must outlive the pass that failed to mix it")
        _ = await library.recoverRecordings(now: Date().addingTimeInterval(Library.trackLifetime + 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingTracks.unmixed(for: file).path))
    }

    func testRecoveryKeepsWhatWasAddedToTheSessionMeanwhile() async throws {
        let library = Library(root: folder)
        var session = try library.newMeeting(title: "Busy", date: Date())
        let file = library.folder(of: session).appendingPathComponent("recording-100000.m4a")
        await track(file, duration: 2)
        await track(RecordingTracks.system(for: file), duration: 2, beepOffset: 0.25)
        try place(systemTrackOf: file, after: 0)
        session.recordings = [RecordingInfo(file: file.lastPathComponent, start: Date(), duration: 2)]
        try library.save(session)

        // the pass starts with the session as it is now; a note and a second recording arrive while it works
        async let pass = library.recoverRecordings()
        var edited = try XCTUnwrap(library.reload(session))
        edited.markers.append(Marker(recording: file.lastPathComponent, time: 1, text: "typed meanwhile"))
        edited.recordings.append(RecordingInfo(file: "recording-110000.m4a", start: Date(), duration: 5))
        try library.save(edited)
        _ = await pass

        let after = try XCTUnwrap(library.reload(session))
        XCTAssertEqual(after.recordings.first?.systemAudio?.status, .mixed)
        // the edit either landed before the pass read the session again or after it saved: never lost in between
        if after.markers.isEmpty {
            try library.save(edited)
        } else {
            XCTAssertEqual(after.markers.map(\.text), ["typed meanwhile"])
            XCTAssertEqual(after.recordings.map(\.file), [file.lastPathComponent, "recording-110000.m4a"])
        }
    }

    func testLaunchFinishesAMeetingACrashLeftOpen() async throws {
        let library = Library(root: folder)
        var session = try library.newMeeting(title: "Standup", date: Date())
        let file = library.folder(of: session).appendingPathComponent("recording-100000.m4a")
        await track(file, duration: 4)
        await track(RecordingTracks.system(for: file), duration: 3, beepOffset: 0.25)
        try place(systemTrackOf: file, after: 0.5)
        var info = RecordingInfo(file: file.lastPathComponent, start: Date(), inProgress: true)
        // a process id that is alive but is not a recorder: this test itself
        info.recorderPID = getpid()
        var neverStarted = RecordingInfo(file: "recording-100500.m4a", start: Date(), inProgress: true)
        neverStarted.recorderPID = 1
        session.recordings = [info, neverStarted]
        try library.save(session)

        let changed = await library.recoverRecordings()
        XCTAssertEqual(changed, 1)
        let recovered = try XCTUnwrap(library.reload(session))
        XCTAssertEqual(recovered.recordings.map(\.file), [file.lastPathComponent], "an entry without a file is dropped")
        let recording = try XCTUnwrap(recovered.recordings.first)
        XCTAssertFalse(recording.inProgress)
        XCTAssertNil(recording.recorderPID)
        XCTAssertEqual(recording.systemAudio?.status, .mixed)
        XCTAssertEqual(recording.duration ?? 0, 4, accuracy: 0.1)
        try assertBeeps(file, at: [0, 0.75, 1, 1.75, 2, 2.75, 3])

        let again = await library.recoverRecordings()
        XCTAssertEqual(again, 0, "nothing is left to do")
        // the hidden tracks go once they are old
        let later = await library.recoverRecordings(now: Date().addingTimeInterval(Library.trackLifetime + 60))
        XCTAssertEqual(later, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingTracks.microphone(for: file).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingTracks.computer(for: file).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testARefusedMeetingIsThrownAwayAtLaunchEvenIfTheAppDiedFirst() async throws {
        let library = Library(root: folder)
        var refused = try library.newMeeting(title: "Voice message", date: Date())
        let file = library.folder(of: refused).appendingPathComponent("recording-100000.m4a")
        await track(file, duration: 2)
        var info = RecordingInfo(file: file.lastPathComponent, start: Date(), inProgress: true)
        info.recorderPID = 1
        refused.recordings = [info]
        try library.save(refused)
        let kept = try library.newMeeting(title: "Standup", date: Date().addingTimeInterval(-3600))
        // the user said "not a meeting", then the app died before the folder was gone
        library.markDiscarded(refused)
        XCTAssertTrue(library.isDiscarded(refused))

        let changed = await library.recoverRecordings()
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(library.meetings().map(\.id), [kept.id], "the refused one never comes back as a meeting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.folder(of: refused).path))
    }

    func testARecordingStillBeingWrittenIsLeftAlone() async throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("lectern-recorder")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "helper not built at \(helper.path)")
        let library = Library(root: folder)
        var session = try library.newMeeting(title: "Live", date: Date())
        let file = library.folder(of: session).appendingPathComponent("recording-100000.m4a")
        let client = RecorderClient(helper: helper, output: file)
        let started = try await client.start(simulate: 60, systemAudio: true)
        var info = RecordingInfo(file: file.lastPathComponent, start: started, inProgress: true)
        info.recorderPID = client.pid
        session.recordings = [info]
        try library.save(session)

        let changed = await library.recoverRecordings()
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(library.reload(session)?.recordings.first?.inProgress, true)
        XCTAssertNotNil(RecorderClient.attach(pid: try XCTUnwrap(client.pid), output: file))
        XCTAssertNil(RecorderClient.attach(pid: getpid(), output: file), "any other process is refused")
        await client.stop()
    }
}
