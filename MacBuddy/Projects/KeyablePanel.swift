import AppKit
import SwiftUI

/// Borderless, non-activating panel that can still become key, so the prompt
/// accepts typing without yanking focus away from the frontmost app.
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Wraps a SwiftUI view in the shared floating-prompt chrome: borderless
    /// material panel, centered in the upper part of the main screen, shown on
    /// every Space.
    static func present(_ root: some View, onCancel: @escaping () -> Void) -> KeyablePanel {
        // The panels float over arbitrary desktops; they're always dark glass.
        let hosting = NSHostingView(rootView: root.preferredColorScheme(.dark).tint(Theme.amber))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = KeyablePanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.onCancel = onCancel
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = hosting.frame.size
            // Anchor the top edge so tall content grows downward, Spotlight-style.
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + visible.height * 0.75 - size.height
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(hosting)
        return panel
    }
}
