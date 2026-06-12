import AppKit
import SwiftUI

/// Invisible NSView that grabs first responder while recording so it can see
/// raw key events (including ⌘-combos via `performKeyEquivalent`).
struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onEvent: (NSEvent) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onEvent = onEvent
        if isRecording {
            if view.window?.firstResponder !== view {
                view.window?.makeFirstResponder(view)
            }
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }

    final class CaptureView: NSView {
        var onEvent: ((NSEvent) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            onEvent?(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else {
                return super.performKeyEquivalent(with: event)
            }
            onEvent?(event)
            return true
        }
    }
}
