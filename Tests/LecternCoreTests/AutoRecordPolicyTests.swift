import XCTest
@testable import LecternCore

/// The policy is driven second by second with who holds the microphone, like the app does.
final class AutoRecordPolicyTests: XCTestCase {
    let zoomMic = AudioUser(bundle: "us.zoom.xos", input: true, output: true)
    let zoomSound = AudioUser(bundle: "us.zoom.xos", input: false, output: true)
    let slackMic = AudioUser(bundle: "com.tinyspeck.slackmacgap", input: true)
    let music = AudioUser(bundle: "com.apple.Music", input: false, output: true)
    let dictation = AudioUser(bundle: "com.apple.SpeechRecognitionCore", input: true)

    var policy = AutoRecordPolicy()
    var now = Date(timeIntervalSince1970: 1_000_000)
    var busy = false

    override func setUp() {
        policy = AutoRecordPolicy()
        policy.setEnabled(true, now: now)
    }

    /// Runs `seconds` ticks with the same users and returns every effect, with the second it came in.
    @discardableResult
    func run(_ seconds: Int, _ users: [AudioUser]) -> [(Int, AutoRecordPolicy.Effect)] {
        var all: [(Int, AutoRecordPolicy.Effect)] = []
        for second in 1...seconds {
            now.addTimeInterval(1)
            for effect in policy.observe(users, recorderBusy: busy, now: now) { all.append((second, effect)) }
        }
        return all
    }

    func started(_ effects: [(Int, AutoRecordPolicy.Effect)]) -> AutoRecordPolicy.Start? {
        for (_, effect) in effects { if case .start(let start) = effect { return start } }
        return nil
    }

    func testAMeetingAppOnTheMicrophoneStartsAfterFourSeconds() {
        XCTAssertTrue(run(4, [zoomMic]).isEmpty, "the first tick sees it, four seconds later it has held for four")
        let effects = run(1, [zoomMic])
        let start = started(effects)
        XCTAssertEqual(start?.app.id, "zoom")
        XCTAssertEqual(start?.ask, false)
        XCTAssertEqual(start?.recording.confirmed, true)
        XCTAssertEqual(policy.current?.app, "zoom")
        XCTAssertTrue(run(60, [zoomMic]).isEmpty, "one recording, not one a second")
    }

    func testAShortUseOfTheMicrophoneAndOtherAppsStartNothing() {
        run(3, [zoomMic])
        XCTAssertTrue(run(10, []).isEmpty)
        XCTAssertTrue(run(30, [dictation, music]).isEmpty)
        XCTAssertNil(policy.current)
    }

    func testAnotherAppTakingOverCountsItsOwnFourSeconds() {
        run(3, [slackMic])
        XCTAssertTrue(run(4, [zoomMic]).isEmpty)
        XCTAssertEqual(started(run(1, [zoomMic]))?.app.id, "zoom")
    }

    func testTheRecordingEndsThreeMinutesAfterTheCall() {
        run(5, [slackMic])
        XCTAssertTrue(run(600, [slackMic]).isEmpty)
        let effects = run(200, [])
        // asked for again every ten seconds until the recording is reported over
        XCTAssertEqual(effects.map(\.0), [180, 190, 200])
        XCTAssertEqual(effects.first?.1, .stop)
        policy.ended(.finished, now: now)
        XCTAssertTrue(run(60, []).isEmpty)
        XCTAssertNil(policy.current)
        XCTAssertFalse(policy.suppressed)
    }

    func testAShortSilenceDoesNotEndIt() {
        run(5, [slackMic])
        for _ in 0..<5 {
            XCTAssertTrue(run(170, []).isEmpty)
            XCTAssertTrue(run(20, [slackMic]).isEmpty)
        }
    }

    func testZoomMutedStillCountsWhileItPlaysSound() {
        run(5, [zoomMic])
        XCTAssertTrue(run(900, [zoomSound]).isEmpty, "muted, microphone released, the call goes on")
        XCTAssertEqual(run(181, [music]).map(\.1), [.stop])
    }

    func testStoppingByHandDoesNotStartAgainOnTheSameCall() {
        run(5, [zoomMic])
        policy.ended(.stoppedByUser, now: now)
        XCTAssertTrue(policy.suppressed)
        XCTAssertTrue(run(600, [zoomMic]).isEmpty)
        // the call ends; half a minute of quiet later a new one is recorded again
        XCTAssertTrue(run(31, []).isEmpty)
        XCTAssertFalse(policy.suppressed)
        XCTAssertEqual(started(run(5, [zoomMic]))?.app.id, "zoom")
    }

    func testNothingStartsWhileALectureIsBeingRecordedNorOnTheCallThatWasOnThen() {
        busy = true
        XCTAssertTrue(run(60, [zoomMic]).isEmpty)
        // the lecture ends in the middle of the call: that call is left alone
        busy = false
        XCTAssertTrue(run(120, [zoomMic]).isEmpty)
        XCTAssertTrue(run(31, []).isEmpty)
        XCTAssertNotNil(started(run(5, [zoomMic])))
    }

    func testARecordingMadeByHandWithNoCallOnDoesNotBlockTheNextMeeting() {
        busy = true
        run(30, [])
        busy = false
        run(2, [])
        XCTAssertNotNil(started(run(5, [zoomMic])))
    }

    func testTurnedOffNothingStartsAndTurnedOnInACallWaitsForTheNext() {
        policy.setEnabled(false, now: now)
        XCTAssertTrue(run(30, [zoomMic]).isEmpty)
        policy.setEnabled(true, now: now)
        XCTAssertTrue(run(120, [zoomMic]).isEmpty)
        XCTAssertTrue(run(31, []).isEmpty)
        XCTAssertNotNil(started(run(5, [zoomMic])))
    }

    func testTurningItOffLetsARunningRecordingEndOnItsOwn() {
        run(5, [zoomMic])
        policy.setEnabled(false, now: now)
        XCTAssertEqual(run(181, []).map(\.1), [.stop])
    }

    func testAFailedStartIsNotTriedAgainOnTheSameCall() {
        XCTAssertNotNil(started(run(5, [zoomMic])))
        policy.ended(.failed, now: now)
        XCTAssertTrue(run(300, [zoomMic]).isEmpty)
        XCTAssertTrue(run(31, []).isEmpty)
        XCTAssertNotNil(started(run(5, [zoomMic])), "the next call is")
    }

    func testARecordingTakenOverAfterARestartStillEndsWithTheCall() {
        policy.adopt(AutomaticRecording(app: "zoom"), now: now)
        XCTAssertTrue(run(300, [zoomMic]).isEmpty)
        XCTAssertEqual(run(181, []).map(\.1), [.stop])
    }
}
