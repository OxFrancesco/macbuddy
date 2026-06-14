import CoreGraphics
import Foundation
import Testing

struct MenuBarIconLogicTests {
    @Test func classifierUsesSeparatorRelativeZones() {
        let separator = CGRect(x: 500, y: 0, width: 1, height: 24)
        let keep = makeIcon(id: "keep", frame: CGRect(x: 560, y: 0, width: 20, height: 20))
        let hidden = makeIcon(id: "hidden", frame: CGRect(x: 440, y: 0, width: 20, height: 20))

        let classified = MenuBarIconZoneClassifier.classify(
            [keep, hidden],
            separatorFrame: separator,
            hiddenIDs: [],
            appBundleIdentifier: "dev.francescooddo.macbuddy"
        )

        #expect(zone(for: "keep", in: classified) == .keep)
        #expect(zone(for: "hidden", in: classified) == .hidden)
    }

    @Test func physicalSeparatorWinsOverStoredHiddenIntent() {
        let separator = CGRect(x: 500, y: 0, width: 1, height: 24)
        let icon = makeIcon(id: "clockwise", frame: CGRect(x: 650, y: 0, width: 20, height: 20))

        let classified = MenuBarIconZoneClassifier.classify(
            [icon],
            separatorFrame: separator,
            hiddenIDs: ["clockwise"],
            appBundleIdentifier: "dev.francescooddo.macbuddy"
        )

        #expect(classified.first?.zone == .keep)
    }

    @Test func hiddenIntentIsFallbackWhenSeparatorIsMissing() {
        let icon = makeIcon(id: "clockwise", frame: CGRect(x: 650, y: 0, width: 20, height: 20))

        let classified = MenuBarIconZoneClassifier.classify(
            [icon],
            separatorFrame: nil,
            hiddenIDs: ["clockwise"],
            appBundleIdentifier: "dev.francescooddo.macbuddy"
        )

        #expect(classified.first?.zone == .hidden)
    }

    @Test func systemItemsStayInSystemZone() {
        let icon = makeIcon(
            id: "wifi",
            bundleIdentifier: "com.apple.controlcenter",
            frame: CGRect(x: 300, y: 0, width: 20, height: 20),
            isSystemItem: true
        )

        let classified = MenuBarIconZoneClassifier.classify(
            [icon],
            separatorFrame: CGRect(x: 500, y: 0, width: 1, height: 24),
            hiddenIDs: ["wifi"],
            appBundleIdentifier: "dev.francescooddo.macbuddy"
        )

        #expect(classified.first?.zone == .system)
    }

    @Test func macBuddyOwnedItemsAreFilteredOut() {
        let icon = makeIcon(
            id: "macbuddy",
            bundleIdentifier: "dev.francescooddo.macbuddy",
            frame: CGRect(x: 700, y: 0, width: 20, height: 20)
        )

        let classified = MenuBarIconZoneClassifier.classify(
            [icon],
            separatorFrame: nil,
            hiddenIDs: [],
            appBundleIdentifier: "dev.francescooddo.macbuddy"
        )

        #expect(classified.isEmpty)
    }

    @Test func safetyRejectsMissingPermission() {
        let error = MenuBarMoveSafety.validate(
            accessibilityTrusted: false,
            separatorFrame: CGRect(x: 500, y: 0, width: 1, height: 24),
            macBuddyAnchorVisible: true,
            icon: makeIcon(),
            origin: .userAction
        )

        #expect(error == .accessibilityPermissionMissing)
    }

    @Test func safetyRejectsMissingSeparator() {
        let error = MenuBarMoveSafety.validate(
            accessibilityTrusted: true,
            separatorFrame: nil,
            macBuddyAnchorVisible: true,
            icon: makeIcon(),
            origin: .userAction
        )

        #expect(error == .missingSeparator)
    }

    @Test func safetyRejectsMissingMacBuddyAnchor() {
        let error = MenuBarMoveSafety.validate(
            accessibilityTrusted: true,
            separatorFrame: CGRect(x: 500, y: 0, width: 1, height: 24),
            macBuddyAnchorVisible: false,
            icon: makeIcon(),
            origin: .userAction
        )

        #expect(error == .missingMacBuddyAnchor)
    }

    @Test func safetyRejectsSystemItems() {
        let error = MenuBarMoveSafety.validate(
            accessibilityTrusted: true,
            separatorFrame: CGRect(x: 500, y: 0, width: 1, height: 24),
            macBuddyAnchorVisible: true,
            icon: makeIcon(bundleIdentifier: "com.apple.controlcenter", isSystemItem: true),
            origin: .userAction
        )

        #expect(error == .lockedSystemItem)
    }

    @Test func safetyRejectsAutomaticStartupAndWakeMoves() {
        let separator = CGRect(x: 500, y: 0, width: 1, height: 24)

        #expect(MenuBarMoveSafety.validate(
            accessibilityTrusted: true,
            separatorFrame: separator,
            macBuddyAnchorVisible: true,
            icon: makeIcon(),
            origin: .startup
        ) == .automaticMoveRefused)

        #expect(MenuBarMoveSafety.validate(
            accessibilityTrusted: true,
            separatorFrame: separator,
            macBuddyAnchorVisible: true,
            icon: makeIcon(),
            origin: .wake
        ) == .automaticMoveRefused)

        #expect(MenuBarMoveSafety.validate(
            accessibilityTrusted: true,
            separatorFrame: separator,
            macBuddyAnchorVisible: true,
            icon: makeIcon(),
            origin: .recovery
        ) == .automaticMoveRefused)
    }

    @Test func stableIDsOnlyAddOrdinalsForDuplicates() {
        let baseID = MenuBarIconIdentity.baseID(
            bundleIdentifier: "com.example.Utility",
            ownerName: "Utility",
            title: "  Sync Status  ",
            description: nil,
            help: nil
        )

        #expect(baseID == "com.example.utility::sync status")
        #expect(MenuBarIconIdentity.id(baseID: baseID, ordinal: 1, duplicateCount: 1) == baseID)
        #expect(MenuBarIconIdentity.id(baseID: baseID, ordinal: 2, duplicateCount: 3) == "\(baseID)#2")
    }

    @Test func storePersistsHiddenIDsAndRevealState() throws {
        let suiteName = "MacBuddyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MenuBarIconStore(defaults: defaults)

        #expect(store.hiddenItemsRevealed)

        store.setHidden(true, for: "com.example.utility::sync")
        #expect(!store.hiddenItemsRevealed)
        store.hiddenItemsRevealed = false

        let reloadedStore = MenuBarIconStore(defaults: defaults)
        #expect(reloadedStore.hiddenIconIDs == ["com.example.utility::sync"])
        #expect(!reloadedStore.hiddenItemsRevealed)

        reloadedStore.setHidden(false, for: "com.example.utility::sync")
        #expect(reloadedStore.hiddenIconIDs.isEmpty)
    }

    @Test func dragPlannerTargetsOppositeSidesOfSeparator() {
        let iconFrame = CGRect(x: 600, y: 4, width: 20, height: 20)
        let separator = CGRect(x: 500, y: 0, width: 1, height: 24)

        let hiddenPlan = MenuBarIconDragPlanner.plan(
            iconFrame: iconFrame,
            separatorFrame: separator,
            direction: .hidden
        )
        let keepPlan = MenuBarIconDragPlanner.plan(
            iconFrame: iconFrame,
            separatorFrame: separator,
            direction: .keep
        )

        #expect(hiddenPlan.start == CGPoint(x: 610, y: 14))
        #expect(hiddenPlan.end.x < separator.minX)
        #expect(keepPlan.end.x > separator.maxX)
    }

    @Test func collapsedAnchorLengthIsBoundedToCurrentScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1_600, height: 900)

        #expect(MenuBarAnchorLayout.collapsedLength(
            separatorFrame: nil,
            screenFrame: nil
        ) == 360)
        #expect(MenuBarAnchorLayout.collapsedLength(
            separatorFrame: nil,
            screenFrame: screen
        ) == 1_656)
        #expect(MenuBarAnchorLayout.collapsedLength(
            separatorFrame: CGRect(x: 1_500, y: 0, width: 14, height: 24),
            screenFrame: screen
        ) == 1_570)
        #expect(MenuBarAnchorLayout.collapsedLength(
            separatorFrame: CGRect(x: 4_000, y: 0, width: 14, height: 24),
            screenFrame: screen
        ) == 1_656)
    }

    private func zone(for id: String, in icons: [MenuBarIconSnapshot]) -> MenuBarIconZone? {
        icons.first { $0.id == id }?.zone
    }

    private func makeIcon(
        id: String = "icon",
        bundleIdentifier: String = "com.example.utility",
        frame: CGRect = CGRect(x: 600, y: 0, width: 20, height: 20),
        isSystemItem: Bool = false
    ) -> MenuBarIconSnapshot {
        MenuBarIconSnapshot(
            id: id,
            identityBase: id,
            ownerBundleIdentifier: bundleIdentifier,
            ownerName: "Utility",
            processIdentifier: 100,
            title: "Utility",
            accessibilityDescription: nil,
            help: nil,
            frame: frame,
            isSystemItem: isSystemItem,
            zone: .keep
        )
    }
}
