import AppKit
import ApplicationServices

nonisolated enum MenuBarAccessibilityScanner {
    private static let axMessagingTimeout: Float = 0.08

    struct Entry {
        let snapshot: MenuBarIconSnapshot
        let element: AXUIElement?
    }

    static func scanMenuBarIcons(
        appBundleIdentifier: String?,
        includeMacBuddy: Bool = false
    ) -> [MenuBarIconSnapshot] {
        scanMenuBarIconEntries(
            appBundleIdentifier: appBundleIdentifier,
            includeMacBuddy: includeMacBuddy,
            retainElements: false
        )
        .map(\.snapshot)
    }

    static func scanMenuBarIconEntries(
        appBundleIdentifier: String?,
        includeMacBuddy: Bool = false,
        retainElements: Bool
    ) -> [Entry] {
        guard AXIsProcessTrusted() else { return [] }

        let drafts = collectDrafts(
            appBundleIdentifier: appBundleIdentifier,
            includeMacBuddy: includeMacBuddy,
            retainElements: retainElements
        )
        let grouped = Dictionary(grouping: drafts, by: \.identityBase)
        var entries: [Entry] = []

        for (_, drafts) in grouped {
            let sortedDrafts = drafts.sorted { $0.snapshot.frame.minX < $1.snapshot.frame.minX }
            for (index, draft) in sortedDrafts.enumerated() {
                var snapshot = draft.snapshot
                snapshot.id = MenuBarIconIdentity.id(
                    baseID: snapshot.identityBase,
                    ordinal: index + 1,
                    duplicateCount: sortedDrafts.count
                )
                entries.append(Entry(snapshot: snapshot, element: draft.element))
            }
        }

        return entries.sorted { lhs, rhs in
            if lhs.snapshot.frame.minX == rhs.snapshot.frame.minX {
                return lhs.snapshot.displayName < rhs.snapshot.displayName
            }
            return lhs.snapshot.frame.minX < rhs.snapshot.frame.minX
        }
    }

    private struct Draft {
        let snapshot: MenuBarIconSnapshot
        let element: AXUIElement?

        var identityBase: String {
            snapshot.identityBase
        }
    }

    private static func collectDrafts(
        appBundleIdentifier: String?,
        includeMacBuddy: Bool,
        retainElements: Bool
    ) -> [Draft] {
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
            guard let extrasMenuBar = axElement(from: extrasValue) else { continue }
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
                drafts.append(
                    Draft(
                        snapshot: snapshot,
                        element: retainElements ? child : nil
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

    private static func axElement(from value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axValue(from value: CFTypeRef, type: AXValueType) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = (value as! AXValue)
        guard AXValueGetType(axValue) == type else { return nil }
        return axValue
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = copyAttribute(kAXPositionAttribute, from: element),
              let sizeRef = copyAttribute(kAXSizeAttribute, from: element),
              let positionValue = axValue(from: positionRef, type: .cgPoint),
              let sizeValue = axValue(from: sizeRef, type: .cgSize) else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }
}
