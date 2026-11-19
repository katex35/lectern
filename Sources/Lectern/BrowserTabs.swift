import AppKit
import LecternCore

/// Reads the address in front of every window of a browser, to tell a meeting from any other page
/// that uses the microphone. Addresses are looked at and forgotten: nothing is stored or sent.
///
/// macOS asks the user once per browser whether Lectern may do this (Automation). Without it, or for
/// a browser that cannot be asked (Firefox), a recording still starts and the user is asked instead.
enum BrowserTabs {
    /// Reading happens here, never on the main thread: a browser may take seconds to answer.
    static let queue = DispatchQueue(label: "lectern.meetings.tabs")
    /// Browsers the user was already asked about in this run. On `queue`.
    private static var asked = Set<String>()

    /// `noErr`: allowed. `errAEEventNotPermitted`: refused. `errAEEventWouldRequireUserConsent`: not
    /// asked yet. `procNotFound`: the browser is not running. With `ask` the user is asked and the
    /// call waits for the answer.
    static func permission(for bundle: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let created = bundle.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }

    /// Asks once when it was never asked. The dialog waits for the user; reading tabs does not wait for it.
    /// On `queue`.
    static func askOnce(_ bundle: String) {
        guard permission(for: bundle, ask: false) == OSStatus(errAEEventWouldRequireUserConsent),
              asked.insert(bundle).inserted else { return }
        DispatchQueue.global().async { _ = permission(for: bundle, ask: true) }
    }

    static func running(_ bundles: [String]) -> [String] {
        bundles.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Runs a program and reads what it prints; nil when it does not finish in time (it is ended then).
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // read apart from waiting: many windows must not fill the pipe and stall the program
        var data = Data()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            _ = read.wait(timeout: .now() + 1)
            return nil
        }
        guard read.wait(timeout: .now() + 2) == .success else { return nil }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The address of the front tab of every window. A meeting forgotten in a background tab does not
    /// count. Nil without permission, for a browser that does not answer, or one that cannot be asked.
    /// On `queue`.
    static func frontAddresses(of bundle: String) -> [String]? {
        guard permission(for: bundle, ask: false) == noErr else {
            askOnce(bundle)
            return nil
        }
        let front = bundle == "com.apple.Safari" ? "current tab" : "active tab"
        // a browser that quit meanwhile is not opened again by asking it
        let script = """
        set out to ""
        if application id "\(bundle)" is not running then return out
        with timeout of 4 seconds
        tell application id "\(bundle)"
        repeat with w in windows
        try
        set out to out & (URL of \(front) of w as text) & linefeed
        end try
        end repeat
        end tell
        end timeout
        return out
        """
        guard let result = run("/usr/bin/osascript", ["-e", script], timeout: 6), result.status == 0 else { return nil }
        return result.output.split(separator: "\n").map(String.init)
    }

    /// The first front tab that is a meeting, and the browser showing it. On `queue`.
    static func meeting(in bundles: [String]) -> MeetingTab? {
        for bundle in bundles {
            for address in frontAddresses(of: bundle) ?? [] {
                if let service = MeetingService.name(for: address) { return MeetingTab(service: service, browser: bundle) }
            }
        }
        return nil
    }
}
