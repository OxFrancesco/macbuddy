import AppKit
import ApplicationServices

@MainActor
final class MenuBarAccessibilityService {
    private var elementsByID: [String: AXUIElement] = [:]
    private let appBundleIdentifier = Bundle.main.bundleIdentifier

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestTrustPrompt() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openControlCenterSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.dock") {
            NSWorkspace.shared.open(fallback)
        }
    }

    func scanMenuBarIcons(includeMacBuddy: Bool = false) -> [MenuBarIconSnapshot] {
        let entries = MenuBarAccessibilityScanner.scanMenuBarIconEntries(
            appBundleIdentifier: appBundleIdentifier,
            includeMacBuddy: includeMacBuddy,
            retainElements: true
        )
        elementsByID = [:]
        for entry in entries {
            if let element = entry.element {
                elementsByID[entry.snapshot.id] = element
            }
        }
        return entries.map(\.snapshot)
    }

    func activate(_ icon: MenuBarIconSnapshot) -> Bool {
        if elementsByID[icon.id] == nil {
            _ = scanMenuBarIcons(includeMacBuddy: false)
        }
        guard let element = elementsByID[icon.id] else {
            return false
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    func hasVisibleMacBuddyControl() -> Bool {
        MenuBarAccessibilityScanner.scanMenuBarIcons(
            appBundleIdentifier: appBundleIdentifier,
            includeMacBuddy: true
        )
        .contains { icon in
            guard icon.ownerBundleIdentifier == appBundleIdentifier else {
                return false
            }
            return icon.frame.width >= 8 && frameIntersectsAnyScreen(icon.frame)
        }
    }

    private func frameIntersectsAnyScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.intersects(frame)
        } || frame.maxX > 0
    }
}
