import Foundation
import LecternCore
import ServiceManagement

/// What the user chose for meetings, kept in the app's defaults.
enum MeetingSettings {
    static let systemAudioKey = "meetings.systemAudio"
    static let autoRecordKey = "meetings.autoRecord"
    static let controlKey = "meetings.control"

    /// `Lectern --meeting ...` may start and stop recordings. Off unless turned on: the command
    /// reaches the app through notifications any program on this Mac can send, and Lectern must not
    /// lend its microphone permission to whoever asks.
    static var allowsControl: Bool { UserDefaults.standard.bool(forKey: controlKey) }
    /// An automatic recording ends by itself when the app has been gone this long.
    static let watchdog: Double = 180
    /// A meeting may run longer than a lecture before the recorder stops on its own.
    static let maxDuration: Double = 8 * 3600

    /// The other side of a call (what the Mac plays) is recorded with the microphone. On unless turned off.
    static var recordsSystemAudio: Bool {
        guard SystemAudioRecorder.isSupported else { return false }
        return UserDefaults.standard.object(forKey: systemAudioKey) as? Bool ?? true
    }

    /// Who holds the microphone is read from a list macOS has kept since 14.2, like the audio tap.
    static var canAutoRecord: Bool { SystemAudioRecorder.isSupported }

    /// A meeting app opening the microphone starts a recording. Off unless turned on.
    static var autoRecords: Bool {
        canAutoRecord && UserDefaults.standard.bool(forKey: autoRecordKey)
    }
}

/// Lectern in the user's login items, so meetings are noticed without opening it first.
enum LoginItem {
    /// Login items belong to an app bundle; `swift run` has none.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static var isOn: Bool { isAvailable && SMAppService.mainApp.status == .enabled }

    /// Returns what is true afterwards.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard isAvailable else { return false }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            return isOn
        }
        return isOn
    }
}
