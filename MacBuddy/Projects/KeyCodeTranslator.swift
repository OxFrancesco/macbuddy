import Carbon

/// Translates virtual key codes into human-readable labels using the current
/// keyboard layout, falling back to a fixed table for non-printing keys.
nonisolated enum KeyCodeTranslator {
    static func label(for keyCode: UInt32) -> String {
        if let special = specialKeyLabels[keyCode] {
            special
        } else {
            layoutLabel(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    private static func layoutLabel(for keyCode: UInt32) -> String? {
        guard let layoutData = keyboardLayoutData() else { return nil }
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let layoutPointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layoutPointer,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static func keyboardLayoutData() -> Data? {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()
        ]
        for unmanaged in sources {
            guard let source = unmanaged?.takeRetainedValue(),
                  let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                continue
            }
            return Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
        }
        return nil
    }

    private static let specialKeyLabels: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌅",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦",
        118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
