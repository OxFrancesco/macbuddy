import AppKit

/// Borderless, non-activating panel that can still become key, so the prompt
/// accepts typing without yanking focus away from the frontmost app.
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
