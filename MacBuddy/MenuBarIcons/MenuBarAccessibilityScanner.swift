import AppKit
import ApplicationServices

nonisolated enum MenuBarAccessibilityScanner {
    private static let axMessagingTimeout: Float = 0.08

    static func scanMenuBarIcons(
        appBundleIdentifier: String?,
        includeMacBuddy: Bool = false
    ) -> [MenuBarIconSnapshot] {
        guard AXIsProcessTrusted() else { return [] }

        let drafts = collectDrafts(
            appBundleIdentifier: appBundleIdentifier,
            includeMacBuddy: includeMacBuddy
        )
        let grouped = Dictionary(grouping: drafts, by: \.identityBase)
        var icons: [MenuBarIconSnapshot] = []

        for (_, entries) in grouped {
            let sortedEntries = entries.sorted { $0.frame.minX < $1.frame.minX }
            for (index, entry) in sortedEntries.enumerated() {
                var snapshot = entry
                snapshot.id = MenuBarIconIdentity.id(
                    baseID: snapshot.identityBase,
                    ordinal: index + 1,
                    duplicateCount: sortedEntries.count
                )
                icons.append(snapshot)
            }
        }

        return icons.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX {
                return lhs.displayName < rhs.displayName
            }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    private static func collectDrafts(
        appBundleIdentifier: String?,
        includeMacBuddy: Bool
    ) -> [MenuBarIconSnapshot] {
        var drafts: [MenuBarIconSnapshot] = []
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
                drafts.append(
                    MenuBarIconSnapshot(
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
                )
            }
        }
        return drafts
    }

    private static func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private static func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute, from: element)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
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
}
