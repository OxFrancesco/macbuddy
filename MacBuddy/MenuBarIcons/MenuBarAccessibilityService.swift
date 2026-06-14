import AppKit
import ApplicationServices

@MainActor
final class MenuBarAccessibilityService {
    private let axMessagingTimeout: Float = 0.08
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
        let drafts = collectDrafts(includeMacBuddy: includeMacBuddy)
        elementsByID = [:]

        let grouped = Dictionary(grouping: drafts, by: \.snapshot.identityBase)
        var icons: [MenuBarIconSnapshot] = []
        for (_, entries) in grouped {
            let sortedEntries = entries.sorted { $0.snapshot.frame.minX < $1.snapshot.frame.minX }
            for (index, entry) in sortedEntries.enumerated() {
                var snapshot = entry.snapshot
                snapshot.id = MenuBarIconIdentity.id(
                    baseID: snapshot.identityBase,
                    ordinal: index + 1,
                    duplicateCount: sortedEntries.count
                )
                icons.append(snapshot)
                elementsByID[snapshot.id] = entry.element
            }
        }

        return icons.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX {
                return lhs.displayName < rhs.displayName
            }
            return lhs.frame.minX < rhs.frame.minX
        }
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
        let drafts = collectDrafts(includeMacBuddy: true)
        return drafts.contains { draft in
            guard draft.snapshot.ownerBundleIdentifier == appBundleIdentifier else {
                return false
            }
            return draft.snapshot.frame.width >= 8 && frameIntersectsAnyScreen(draft.snapshot.frame)
        }
    }

    private struct Draft {
        var snapshot: MenuBarIconSnapshot
        let element: AXUIElement
    }

    private func collectDrafts(includeMacBuddy: Bool) -> [Draft] {
        guard isTrusted else { return [] }

        var drafts: [Draft] = []
        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated, app.processIdentifier > 0 else { continue }
            if !includeMacBuddy, app.bundleIdentifier == appBundleIdentifier {
                continue
            }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            _ = AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
            guard let extrasValue = copyAttribute(kAXExtrasMenuBarAttribute, from: appElement) else {
                continue
            }
            let extrasMenuBar = extrasValue as! AXUIElement
            _ = AXUIElementSetMessagingTimeout(extrasMenuBar, axMessagingTimeout)
            guard let children = copyAttribute(kAXChildrenAttribute, from: extrasMenuBar) as? [AXUIElement] else {
                continue
            }

            for child in children {
                _ = AXUIElementSetMessagingTimeout(child, axMessagingTimeout)
                guard role(of: child) == (kAXMenuBarItemRole as String),
                      let frame = frame(of: child),
                      !frame.isEmpty else {
                    continue
                }
                let ownerBundleIdentifier = app.bundleIdentifier
                let ownerName = app.localizedName ?? ownerBundleIdentifier ?? "Unknown App"
                let title = stringAttribute(kAXTitleAttribute, from: child)
                let description = stringAttribute(kAXDescriptionAttribute, from: child)
                let help = stringAttribute(kAXHelpAttribute, from: child)
                let identityBase = MenuBarIconIdentity.baseID(
                    bundleIdentifier: ownerBundleIdentifier,
                    ownerName: ownerName,
                    title: title,
                    description: description,
                    help: help
                )
                let snapshot = MenuBarIconSnapshot(
                    id: identityBase,
                    identityBase: identityBase,
                    ownerBundleIdentifier: ownerBundleIdentifier,
                    ownerName: ownerName,
                    processIdentifier: app.processIdentifier,
                    title: title,
                    accessibilityDescription: description,
                    help: help,
                    frame: frame,
                    isSystemItem: ownerBundleIdentifier?.hasPrefix("com.apple.") == true,
                    zone: .keep
                )
                drafts.append(Draft(snapshot: snapshot, element: child))
            }
        }
        return drafts
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute, from: element)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = copyAttribute(kAXPositionAttribute, from: element),
              let sizeRef = copyAttribute(kAXSizeAttribute, from: element) else {
            return nil
        }
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func frameIntersectsAnyScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.intersects(frame)
        } || frame.maxX > 0
    }
}
