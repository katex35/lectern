import AppKit
import SwiftUI

/// What a small panel under the menu bar says: a line, a detail and one or two buttons.
struct MeetingNotice: View {
    struct Action {
        let title: String
        let run: () -> Void
    }

    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var secondary: Action?
    let primary: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if let secondary {
                    Button(secondary.title, action: secondary.run)
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                }
                Button(primary.title, action: primary.run)
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 28))
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        .environment(\.colorScheme, .light)
    }
}

/// The panel sits in a window that never comes forward, so its buttons take the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small panel under the menu bar. It does not bring Lectern forward and does not take the keyboard
/// from the meeting, shows over full screen apps too, and is left out of screen sharing.
final class MeetingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// On its way out: still on screen for a moment, but no longer a place others keep clear of.
    private var leaving = false

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // pressing a button does not make the panel key: typing stays in the meeting window
        becomesKeyOnlyIfNeeded = true
        // the other side of a shared screen does not see it
        sharingType = .none
        let host = FirstClickHostingView(rootView: content)
        contentView = host
        setContentSize(host.fittingSize)
    }

    /// Under the menu bar, below Lectern's own icon when it can be found, never past the screen's edge.
    func show() {
        let item = NSApp.windows.first { $0.className.contains("NSStatusBarWindow") && $0.isVisible }
        let screen = item?.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            var x = visible.maxX - frame.width - 10
            if let item {
                x = min(max(item.frame.midX - frame.width / 2, visible.minX + 10), visible.maxX - frame.width - 10)
            }
            // below any panel that is already there: an answer never covers "Is this a meeting?"
            let others = NSApp.windows.filter { window in
                guard window !== self, window.isVisible, let panel = window as? MeetingPanel else { return false }
                return !panel.leaving
            }
            let top = others.map(\.frame.minY).min() ?? visible.maxY
            setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 10, top - frame.height - 8)))
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        leaving = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.orderOut(nil) })
    }
}
