import AppKit
import ApplicationServices

@MainActor
final class MenuBarAccessibilityService {
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

    func activate(_ icon: MenuBarIconSnapshot) async -> Bool {
        await Self.pressMenuBarItem(withID: icon.id, appBundleIdentifier: appBundleIdentifier)
    }

    /// Scan and press stay together on the concurrent executor: walking every
    /// app's AX tree is the expensive part, and AXUIElement handles can't hop
    /// actors, so the press happens where the scan found the element.
    @concurrent
    private nonisolated static func pressMenuBarItem(
        withID iconID: String,
        appBundleIdentifier: String?
    ) async -> Bool {
        let entries = MenuBarAccessibilityScanner.scanMenuBarIconEntries(
            appBundleIdentifier: appBundleIdentifier,
            includeMacBuddy: false,
            retainElements: true
        )
        guard let element = entries.first(where: { $0.snapshot.id == iconID })?.element else {
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
