import XCTest
@testable import LecternCore

final class MeetingServiceTests: XCTestCase {
    func testAddressesOfOneCallAreMeetings() {
        let meetings: [(String, String)] = [
            ("https://meet.google.com/abc-defg-hij", "Meet"),
            ("https://meet.google.com/abc-defg-hij?authuser=1", "Meet"),
            ("https://app.zoom.us/wc/81234567890/join?fromPWA=1", "Zoom"),
            ("https://us05web.zoom.us/wc/join/81234567890", "Zoom"),
            ("https://example.zoom.com/wc/912345678/start", "Zoom"),
            ("https://acme.webex.com/meet/jane.doe", "Webex"),
            ("https://acme.webex.com/webappng/sites/acme/meeting/home", "Webex"),
            ("https://acme.webex.com/wbxmjs/joinservice/sites/acme/meeting/download/abc", "Webex"),
            ("https://meet.jit.si/StandupRoom", "Jitsi"),
            ("https://app.slack.com/huddle/T012345/C012345", "Slack"),
            ("https://facetime.apple.com/join#v=1&p=abc", "FaceTime"),
            ("  https://meet.google.com/abc-defg-hij\n", "Meet"),
        ]
        for (address, service) in meetings {
            XCTAssertEqual(MeetingService.name(for: address), service, address)
        }
    }

    func testOtherPagesOfTheSameSitesAreNot() {
        let others = [
            "https://meet.google.com/",
            "https://meet.google.com/landing",
            "https://meet.google.com/new",
            // opens the app, the call is not in the browser
            "https://us05web.zoom.us/j/81234567890",
            "https://app.zoom.us/wc/home",
            "https://zoom.us/signin",
            "https://notzoom.us/wc/81234567890/join",
            "https://acme.webex.com/",
            "https://acme.webex.com/meet",
            "https://meet.jit.si/",
            "https://meet.jit.si/static/about.html",
            "https://app.slack.com/client/T012345/C012345",
            "https://facetime.apple.com/",
            // a chat and a call look the same in the address
            "https://teams.microsoft.com/v2/",
            "https://discord.com/channels/1/2",
            "https://www.youtube.com/watch?v=abc",
            "about:blank",
            "",
        ]
        for address in others {
            XCTAssertNil(MeetingService.name(for: address), address)
        }
    }

    func testAppsAreFoundByBundleOrPath() {
        XCTAssertEqual(MeetingApps.app(for: AudioUser(bundle: "us.zoom.xos", input: true))?.id, "zoom")
        XCTAssertEqual(MeetingApps.app(for: AudioUser(bundle: "com.microsoft.teams2.helper", input: true))?.id, "teams")
        XCTAssertEqual(MeetingApps.app(for: AudioUser(bundle: "", path: "/usr/libexec/avconferenced", input: true))?.id, "facetime")
        XCTAssertEqual(MeetingApps.app(for: AudioUser(bundle: "", path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper", input: true))?.id, "slack")
        XCTAssertNil(MeetingApps.app(for: AudioUser(bundle: "com.apple.Music", input: false, output: true)))
        XCTAssertNil(MeetingApps.app(for: AudioUser(bundle: "", path: "", input: true)))
    }
}
