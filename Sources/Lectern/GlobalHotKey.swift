import AppKit
import Carbon.HIToolbox

/// A key that works whichever app is in front, registered with the system for as long as this object
/// lives. No permission is needed for this: the system only tells the app that its own key was pressed.
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Control-Option-H: free in macOS and in the meeting apps.
    static let helperKey = (code: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥H")

    init?(code: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let key = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { key.action() }
            return noErr
        }, 1, &type, me, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4C435452), id: 1)   // "LCTR"
        // another app holds the key: `deinit` runs for the object given up here and takes the handler away
        guard RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else { return nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
