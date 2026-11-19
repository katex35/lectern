import Foundation

/// Tells from a web address whether the page is one meeting, and which service it is on.
///
/// Only addresses that point at a single call count. A page that looks the same for a chat and for a
/// call (Teams, Discord), a landing page or a sign-in page gives nil: there the user is asked.
public enum MeetingService {
    public static func name(for address: String) -> String? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else { return nil }
        let parts = url.path.lowercased().split(separator: "/").map(String.init)
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        func meetCode(_ s: String) -> Bool { s.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil }
        func zoomNumber(_ s: String) -> Bool { s.count >= 9 && s.allSatisfy { $0.isASCII && $0.isNumber } }

        // meet.google.com/abc-defg-hij
        if host == "meet.google.com" { return parts.first.map(meetCode) == true ? "Meet" : nil }
        // the web client is /wc/<number>/join or /wc/join/<number>; /j/<number> only opens the app,
        // /wc/home is the start page
        if on("zoom.us") || on("zoom.com") {
            guard let wc = parts.firstIndex(of: "wc") else { return nil }
            return parts[(wc + 1)...].prefix(2).contains(where: zoomNumber) ? "Zoom" : nil
        }
        // <site>.webex.com/meet/<room> or the join page
        if on("webex.com") {
            let join = (parts.first == "meet" && parts.count >= 2) || parts.contains("joinservice")
                || (parts.first == "webappng" && parts.contains("meeting"))
            return join ? "Webex" : nil
        }
        if host == "meet.jit.si" { return parts.count == 1 ? "Jitsi" : nil }
        if host == "app.slack.com" { return parts.first == "huddle" ? "Slack" : nil }
        if host == "facetime.apple.com" { return parts.first == "join" ? "FaceTime" : nil }
        return nil
    }
}
