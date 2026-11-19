import CoreAudio
import Darwin
import Foundation

/// A process that has the microphone or the speakers open right now.
public struct AudioUser: Hashable, Sendable {
    public var bundle: String
    public var path: String
    public var pid: Int32
    public var input: Bool
    public var output: Bool

    public init(bundle: String, path: String = "", pid: Int32 = 0, input: Bool, output: Bool = false) {
        self.bundle = bundle
        self.path = path
        self.pid = pid
        self.input = input
        self.output = output
    }
}

/// An app people hold calls in. When one of them opens the microphone a meeting has probably begun.
public struct MeetingApp: Hashable, Sendable {
    public var id: String
    /// As the user knows it: it goes into the title of the recording.
    public var name: String
    /// Bundle id prefixes of the app and of the helper processes that open the microphone for it.
    public var bundles: [String]
    /// Parts of the executable path, for helpers without a bundle id of their own.
    public var paths: [String]
    /// The call goes on while the app plays sound, even with the microphone muted and released.
    public var outputMeansCall = false
    /// The microphone does not always mean a meeting (a browser, a voice message): record and ask.
    public var ask = false
    /// Browsers whose tabs can be read. A front tab that is a known meeting needs no question.
    public var browsers: [String] = []
}

public enum MeetingApps {
    /// Development: `LECTERN_MEETING_TEST_APP=<part of a path>` makes any process whose executable path
    /// contains it count as a meeting app, to try automatic recording without a call.
    static let testApp: MeetingApp? = ProcessInfo.processInfo.environment["LECTERN_MEETING_TEST_APP"]
        .flatMap { $0.isEmpty ? nil : MeetingApp(id: "test", name: "Test", bundles: [], paths: [$0]) }

    public static let all: [MeetingApp] = known + (testApp.map { [$0] } ?? [])

    static let known: [MeetingApp] = [
        .init(id: "zoom", name: "Zoom", bundles: ["us.zoom."], paths: ["zoom.us.app"], outputMeansCall: true),
        .init(id: "teams", name: "Teams", bundles: ["com.microsoft.teams"], paths: ["Microsoft Teams"], outputMeansCall: true),
        .init(id: "facetime", name: "FaceTime", bundles: ["com.apple.FaceTime"], paths: ["/avconferenced"], outputMeansCall: true),
        .init(id: "webex", name: "Webex", bundles: ["com.cisco.webex", "Cisco-Systems.Spark", "com.webex."], paths: ["/Webex.app/"],
              outputMeansCall: true),
        .init(id: "slack", name: "Slack", bundles: ["com.tinyspeck.slackmacgap"], paths: ["/Slack.app/"]),
        .init(id: "discord", name: "Discord", bundles: ["com.hnc.Discord"], paths: ["/Discord.app/"]),
        .init(id: "skype", name: "Skype", bundles: ["com.skype."], paths: ["/Skype.app/"]),
    ]

    public static func app(for user: AudioUser) -> MeetingApp? {
        all.first { app in
            app.bundles.contains { !user.bundle.isEmpty && user.bundle.hasPrefix($0) }
                || app.paths.contains { user.path.contains($0) }
        }
    }

    public static func app(id: String) -> MeetingApp? { all.first { $0.id == id } }
}

/// Who uses the microphone and the speakers, from Core Audio's list of client processes.
public enum AudioUsers {
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func flag(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var a = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr && value != 0
    }

    static func path(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : ""
    }

    /// The processes with audio running in either direction. Empty where the system has no such list.
    public static func current() -> [AudioUser] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { id in
            let input = flag(id, kAudioProcessPropertyIsRunningInput)
            let output = flag(id, kAudioProcessPropertyIsRunningOutput)
            guard input || output else { return nil }
            var pid: pid_t = 0
            var pa = address(kAudioProcessPropertyPID)
            var ps = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &pa, 0, nil, &ps, &pid) == noErr else { return nil }
            var bundle: Unmanaged<CFString>?
            var ba = address(kAudioProcessPropertyBundleID)
            var bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &bundle) { AudioObjectGetPropertyData(id, &ba, 0, nil, &bs, $0) }
            let bundleID = status == noErr ? (bundle?.takeRetainedValue() as String?) ?? "" : ""
            return AudioUser(bundle: bundleID, path: path(of: pid), pid: pid, input: input, output: output)
        }
    }
}
