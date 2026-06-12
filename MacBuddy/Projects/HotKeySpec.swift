import AppKit
import Carbon

nonisolated struct HotKeySpec: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Builds a spec from a recorded key event. Returns nil unless at least one
    /// of ⌘, ⌥, or ⌃ is held, so plain typing can't become a global hotkey.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        carbonModifiers = Self.carbonModifiers(from: flags)
    }

    static let `default` = HotKeySpec(
        keyCode: UInt32(kVK_ANSI_N),
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey)
    )

    static let defaultOpenProject = HotKeySpec(
        keyCode: UInt32(kVK_ANSI_O),
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey)
    )

    var displayString: String {
        keycapLabels.joined()
    }

    /// One label per physical key, for rendering the shortcut as keycaps.
    var keycapLabels: [String] {
        var labels: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { labels.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { labels.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { labels.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { labels.append("⌘") }
        labels.append(KeyCodeTranslator.label(for: keyCode))
        return labels
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
