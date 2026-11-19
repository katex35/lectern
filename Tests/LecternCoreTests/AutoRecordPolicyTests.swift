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
        // the first look finds nobody in a call
        _ = policy.observe([], recorderBusy: false, now: now)
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

    func testACallAlreadyGoingOnWhenThePolicyStartsIsNotJoined() {
        // Lectern is opened, or automatic recording turned on, in the middle of a call
        policy = AutoRecordPolicy()
        policy.setEnabled(true, now: now)
        XCTAssertTrue(run(300, [zoomMic]).isEmpty)
        XCTAssertTrue(policy.suppressed)
        XCTAssertTrue(run(31, []).isEmpty)
        XCTAssertNotNil(started(run(5, [zoomMic])), "the next call is recorded")
    }

    func testOnlyACallThatLastedIsSureEnoughToProcess() {
        run(5, [slackMic])
        // a voice message: the microphone for half a minute, then the usual wait for the end
        run(30, [slackMic])
        XCTAssertTrue(policy.isBrief)
        XCTAssertEqual(run(181, []).map(\.1), [.stop])
        XCTAssertTrue(policy.isBrief, "still brief when the end is asked for")
        policy.ended(.finished, now: now)

        run(31, [])
        run(5, [slackMic])
        run(120, [slackMic])
        XCTAssertFalse(policy.isBrief, "two minutes on the microphone is a call")
    }

    // MARK: browsers and apps that are asked about

    let chromeMic = AudioUser(bundle: "com.google.Chrome.helper", input: true, output: true)
    let chromeSound = AudioUser(bundle: "com.google.Chrome.helper", input: false, output: true)
    let whatsappMic = AudioUser(bundle: "net.whatsapp.WhatsApp", input: true)
    let firefoxMic = AudioUser(bundle: "org.mozilla.firefox", input: true)
    let meet = MeetingTab(service: "Meet", browser: "com.google.Chrome")

    /// The token of the tab reading asked for, if one was.
    func tabsAsked(_ effects: [(Int, AutoRecordPolicy.Effect)]) -> (browsers: [String], token: Int)? {
        for (_, effect) in effects { if case .readTabs(let browsers, let token) = effect { return (browsers, token) } }
        return nil
    }

    func answer(_ token: Int, _ found: MeetingTab?) -> AutoRecordPolicy.Start? {
        for effect in policy.tabsRead(token: token, found: found, recorderBusy: busy, now: now) {
            if case .start(let start) = effect { return start }
        }
        return nil
    }

    func testABrowserOnTheMicrophoneHasItsTabsReadFirst() throws {
        let asked = try XCTUnwrap(tabsAsked(run(5, [chromeMic])))
        XCTAssertEqual(asked.browsers, ["com.google.Chrome"])
        XCTAssertNil(policy.current, "nothing starts before the tabs are known")
        XCTAssertTrue(run(3, [chromeMic]).isEmpty, "and the tabs are not asked for again meanwhile")
        let start = try XCTUnwrap(answer(asked.token, meet))
        XCTAssertEqual(start.service, "Meet")
        XCTAssertFalse(start.ask)
        XCTAssertTrue(start.recording.confirmed)
        XCTAssertEqual(start.recording.keepAlive, ["com.google.Chrome"])
    }

    func testAnUnknownPageStartsAndAsks() throws {
        let asked = try XCTUnwrap(tabsAsked(run(5, [chromeMic])))
        let start = try XCTUnwrap(answer(asked.token, nil))
        XCTAssertNil(start.service)
        XCTAssertTrue(start.ask)
        XCTAssertFalse(start.recording.confirmed, "not processed on its own until the user says yes")
        policy.confirm()
        XCTAssertEqual(policy.current?.confirmed, true)
    }

    func testAppsWithoutReadableTabsAreAskedAboutAtOnce() {
        XCTAssertEqual(started(run(5, [whatsappMic]))?.ask, true)
        policy.ended(.rejected, now: now)
        run(60, [])
        XCTAssertEqual(started(run(5, [firefoxMic]))?.ask, true)
    }

    func testAnAppOfItsOwnComesBeforeABrowser() {
        let start = started(run(5, [chromeMic, zoomMic]))
        XCTAssertEqual(start?.app.id, "zoom")
        XCTAssertEqual(start?.ask, false)
    }

    func testALateTabAnswerStartsNothingAfterTheMicrophoneWasReleased() throws {
        let asked = try XCTUnwrap(tabsAsked(run(5, [chromeMic])))
        run(2, [])
        XCTAssertNil(answer(asked.token, meet))
        // nor when it comes back after a lecture began
        let again = try XCTUnwrap(tabsAsked(run(5, [chromeMic])))
        busy = true
        XCTAssertNil(answer(again.token, meet))
        XCTAssertNil(policy.current)
    }

    func testATabReadingThatNeverComesBackIsGivenUp() throws {
        XCTAssertNotNil(tabsAsked(run(5, [chromeMic])))
        XCTAssertNotNil(tabsAsked(run(21, [chromeMic])), "asked for again once the first one timed out")
    }

    func testNotAMeetingIsNotRecordedAgainUntilTheAppLetsGoOfTheMicrophone() throws {
        XCTAssertEqual(started(run(5, [whatsappMic]))?.ask, true)
        policy.ended(.rejected, now: now)
        XCTAssertTrue(run(120, [whatsappMic]).isEmpty, "the same voice message goes on")
        // another app is not held back by that answer
        XCTAssertEqual(started(run(5, [whatsappMic, zoomMic]))?.app.id, "zoom")
        policy.ended(.finished, now: now)
        XCTAssertTrue(run(31, []).isEmpty)
        XCTAssertEqual(started(run(5, [whatsappMic]))?.app.id, "whatsapp", "half a minute after it let go it counts again")
    }

    /// Ticks second by second and answers every tab reading at once, as a browser does. Returns how
    /// often the tabs were read and the second the end was first asked for.
    func runAnswering(_ seconds: Int, _ users: [AudioUser], tab: MeetingTab?) -> (reads: Int, stoppedAt: Int?) {
        var reads = 0
        var stoppedAt: Int?
        for second in 1...seconds {
            for (_, effect) in run(1, users) {
                if case .readTabs(let browsers, let token) = effect {
                    XCTAssertEqual(browsers, ["com.google.Chrome"])
                    reads += 1
                    _ = policy.tabsRead(token: token, found: tab, recorderBusy: false, now: now)
                } else if effect == .stop, stoppedAt == nil {
                    stoppedAt = second
                }
            }
        }
        return (reads, stoppedAt)
    }

    func testAMutedMeetingInTheBrowserGoesOnWhileItsTabIsInFront() throws {
        let asked = try XCTUnwrap(tabsAsked(run(5, [chromeMic])))
        XCTAssertNotNil(answer(asked.token, meet))
        // muted: Chrome lets go of the microphone but still plays the others
        let muted = runAnswering(600, [chromeSound], tab: meet)
        XCTAssertNil(muted.stoppedAt, "ten minutes muted must not end the recording")
        XCTAssertEqual(muted.reads, 40, "the tab is looked at every fifteen seconds")
        // the tab is closed (music goes on in another one): three minutes after it was last seen the recording ends
        let closed = runAnswering(300, [chromeSound], tab: nil)
        let stopped = try XCTUnwrap(closed.stoppedAt)
        XCTAssertGreaterThanOrEqual(stopped, 165)
        XCTAssertLessThanOrEqual(stopped, 181)
    }

    func testATabKeepsAMutedMeetingForAnHourAtMost() throws {
        let asked = try XCTUnwrap(tabsAsked(run(5, [chromeMic])))
        XCTAssertNotNil(answer(asked.token, meet))
        let stopped = try XCTUnwrap(runAnswering(4200, [chromeSound], tab: meet).stoppedAt)
        // an hour without the microphone, then the usual three minutes
        XCTAssertGreaterThan(stopped, 3600)
        XCTAssertLessThanOrEqual(stopped, 3600 + 181)
    }

    func testARecordingTakenOverAfterARestartStillEndsWithTheCall() {
        policy.adopt(AutomaticRecording(app: "zoom"), now: now)
        XCTAssertTrue(run(300, [zoomMic]).isEmpty)
        XCTAssertEqual(run(181, []).map(\.1), [.stop])
    }
}
