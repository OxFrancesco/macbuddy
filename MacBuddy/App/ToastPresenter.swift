import AppKit
import SwiftUI

/// Shows a transient, click-through confirmation pill near the top of the
/// screen, then fades it out.
enum ToastPresenter {
    static func show(message: String, systemImage: String = "checkmark.circle.fill") {
        let hosting = NSHostingView(rootView: ToastView(message: message, systemImage: systemImage))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.midX - hosting.frame.width / 2,
                y: visible.maxY - hosting.frame.height - 16
            )
            panel.setFrameOrigin(origin)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0.18
            panel.animator().alphaValue = 1
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.35
                panel.animator().alphaValue = 0
            }
            panel.close()
        }
    }
}
