import CoreGraphics
import Foundation

nonisolated enum MenuBarIconZone: String, Codable, Equatable, Sendable {
    case keep
    case hidden
    case system
}

nonisolated enum MenuBarMoveDirection: Equatable, Sendable {
    case keep
    case hidden
}

nonisolated enum MenuBarMoveOrigin: Equatable, Sendable {
    case userAction
    case startup
    case wake
    case recovery
}

nonisolated enum MenuBarIconMoveError: LocalizedError, Equatable, Sendable {
    case accessibilityPermissionMissing
    case missingSeparator
    case missingMacBuddyAnchor
    case lockedSystemItem
    case missingIconFrame
    case automaticMoveRefused
    case dragFailed
    case verificationFailed
    case iconUnavailable

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            "Grant Accessibility access before moving menu bar icons."
        case .missingSeparator:
            "MacBuddy could not find its menu bar boundary item."
        case .missingMacBuddyAnchor:
            "MacBuddy could not verify that its own menu bar control is visible."
        case .lockedSystemItem:
            "Apple system items are managed in System Settings."
        case .missingIconFrame:
            "MacBuddy could not read this icon's menu bar position."
        case .automaticMoveRefused:
            "Menu bar icons are moved only from explicit user actions."
        case .dragFailed:
            "macOS did not accept the menu bar drag."
        case .verificationFailed:
            "The icon did not land in the expected menu bar section."
        case .iconUnavailable:
            "The icon is no longer available in the menu bar."
        }
    }
}

nonisolated struct MenuBarIconSnapshot: Identifiable, Equatable, Sendable {
    var id: String
    let identityBase: String
    let ownerBundleIdentifier: String?
    let ownerName: String
    let processIdentifier: Int32
    let title: String?
    let accessibilityDescription: String?
    let help: String?
    let frame: CGRect
    let isSystemItem: Bool
    var zone: MenuBarIconZone

    var displayName: String {
        firstNonEmpty(title, accessibilityDescription, help, ownerName, ownerBundleIdentifier) ?? "Menu Bar Item"
    }

    var secondaryText: String {
        ownerBundleIdentifier ?? ownerName
    }
}

nonisolated enum MenuBarIconIdentity {
    static func baseID(
        bundleIdentifier: String?,
        ownerName: String,
        title: String?,
        description: String?,
        help: String?
    ) -> String {
        let owner = normalize(bundleIdentifier ?? ownerName)
        let label = normalize(firstNonEmpty(title, description, help, ownerName) ?? "item")
        return "\(owner)::\(label)"
    }

    static func id(baseID: String, ordinal: Int, duplicateCount: Int) -> String {
        duplicateCount > 1 ? "\(baseID)#\(ordinal)" : baseID
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated enum MenuBarIconFilter {
    static func shouldDisplay(_ icon: MenuBarIconSnapshot, appBundleIdentifier: String?) -> Bool {
        guard let appBundleIdentifier, let ownerBundleIdentifier = icon.ownerBundleIdentifier else {
            return true
        }
        return ownerBundleIdentifier != appBundleIdentifier
    }
}

nonisolated enum MenuBarIconZoneClassifier {
    static func classify(
        _ icons: [MenuBarIconSnapshot],
        separatorFrame: CGRect?,
        hiddenIDs: Set<String>,
        appBundleIdentifier: String?
    ) -> [MenuBarIconSnapshot] {
        icons.compactMap { icon in
            guard MenuBarIconFilter.shouldDisplay(icon, appBundleIdentifier: appBundleIdentifier) else {
                return nil
            }
            var classified = icon
            classified.zone = zone(for: icon, separatorFrame: separatorFrame, hiddenIDs: hiddenIDs)
            return classified
        }
    }

    static func zone(
        for icon: MenuBarIconSnapshot,
        separatorFrame: CGRect?,
        hiddenIDs: Set<String>
    ) -> MenuBarIconZone {
        if icon.isSystemItem {
            return .system
        }
        guard let separatorFrame else {
            return hiddenIDs.contains(icon.id) ? .hidden : .keep
        }
        return icon.frame.midX < separatorFrame.minX ? .hidden : .keep
    }
}

nonisolated struct MenuBarIconDragPlan: Equatable, Sendable {
    let start: CGPoint
    let end: CGPoint
}

nonisolated enum MenuBarIconDragPlanner {
    static func plan(
        iconFrame: CGRect,
        separatorFrame: CGRect,
        direction: MenuBarMoveDirection
    ) -> MenuBarIconDragPlan {
        let start = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        let minimumTravel = max(iconFrame.width, 22)
        let endX: CGFloat = switch direction {
        case .hidden:
            separatorFrame.minX - minimumTravel
        case .keep:
            separatorFrame.maxX + minimumTravel
        }
        return MenuBarIconDragPlan(start: start, end: CGPoint(x: endX, y: iconFrame.midY))
    }
}

nonisolated enum MenuBarAnchorLayout {
    static func collapsedLength(
        separatorFrame: CGRect?,
        screenFrame: CGRect?,
        minimumLength: CGFloat = 360,
        trailingPadding: CGFloat = 56
    ) -> CGFloat {
        guard let screenFrame else {
            return minimumLength
        }
        guard let separatorFrame else {
            return screenFrame.width + trailingPadding
        }

        let neededTravel = separatorFrame.maxX - screenFrame.minX + trailingPadding
        return min(max(neededTravel, minimumLength), screenFrame.width + trailingPadding)
    }
}

nonisolated enum MenuBarMoveSafety {
    static func validate(
        accessibilityTrusted: Bool,
        separatorFrame: CGRect?,
        macBuddyAnchorVisible: Bool,
        icon: MenuBarIconSnapshot,
        origin: MenuBarMoveOrigin
    ) -> MenuBarIconMoveError? {
        guard origin == .userAction else {
            return .automaticMoveRefused
        }
        guard accessibilityTrusted else {
            return .accessibilityPermissionMissing
        }
        guard !icon.isSystemItem else {
            return .lockedSystemItem
        }
        guard !icon.frame.isEmpty else {
            return .missingIconFrame
        }
        guard separatorFrame != nil else {
            return .missingSeparator
        }
        guard macBuddyAnchorVisible else {
            return .missingMacBuddyAnchor
        }
        return nil
    }
}

nonisolated func firstNonEmpty(_ values: String?...) -> String? {
    values
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}
