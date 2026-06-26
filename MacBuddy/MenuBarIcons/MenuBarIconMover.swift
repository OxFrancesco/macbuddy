import AppKit
import ApplicationServices
import Foundation

@MainActor
final class MenuBarIconMover {
    private let accessibilityService: MenuBarAccessibilityService
    private let anchorController: MenuBarAnchorController
    private let appBundleIdentifier = Bundle.main.bundleIdentifier

    init(
        accessibilityService: MenuBarAccessibilityService,
        anchorController: MenuBarAnchorController
    ) {
        self.accessibilityService = accessibilityService
        self.anchorController = anchorController
    }

    func move(
        icon: MenuBarIconSnapshot,
        direction: MenuBarMoveDirection,
        origin: MenuBarMoveOrigin = .userAction
    ) async -> Result<Void, MenuBarIconMoveError> {
        anchorController.installIfNeeded()

        let validation = await MenuBarMoveSafety.validate(
            accessibilityTrusted: accessibilityService.isTrusted,
            separatorFrame: anchorController.separatorFrame,
            macBuddyAnchorVisible: {
                anchorController.setHiddenItemsRevealed(true)
                try? await Task.sleep(for: .milliseconds(120))
                return await hasVisibleMacBuddyAnchor()
            },
            icon: icon,
            origin: origin
        )
        let separatorFrame: CGRect
        switch validation {
        case .success(let validatedMove):
            separatorFrame = validatedMove.separatorFrame
        case .failure(let error):
            return .failure(error)
        }

        let plan = MenuBarIconDragPlanner.plan(
            iconFrame: icon.frame,
            separatorFrame: separatorFrame,
            direction: direction
        )
        guard await Self.performCommandDrag(plan) else {
            return .failure(.dragFailed)
        }

        try? await Task.sleep(for: .milliseconds(160))
        return await verify(icon: icon, expectedDirection: direction)
    }

    private func verify(
        icon: MenuBarIconSnapshot,
        expectedDirection: MenuBarMoveDirection
    ) async -> Result<Void, MenuBarIconMoveError> {
        guard let separatorFrame = anchorController.separatorFrame else {
            return .failure(.missingSeparator)
        }
        let appBundleIdentifier = appBundleIdentifier
        let scannedIcons = await Task.detached(priority: .userInitiated) {
            MenuBarAccessibilityScanner.scanMenuBarIcons(
                appBundleIdentifier: appBundleIdentifier
            )
        }.value
        let refreshed = scannedIcons.first { candidate in
            candidate.id == icon.id || candidate.identityBase == icon.identityBase
        }
        guard let refreshed else {
            return .failure(.iconUnavailable)
        }
        let zone = MenuBarIconZoneClassifier.zone(
            for: refreshed,
            separatorFrame: separatorFrame,
            hiddenIDs: []
        )
        switch (expectedDirection, zone) {
        case (.hidden, .hidden), (.keep, .keep):
            return .success(())
        default:
            return .failure(.verificationFailed)
        }
    }

    private func hasVisibleMacBuddyAnchor() async -> Bool {
        let appBundleIdentifier = appBundleIdentifier
        let screenFrames = NSScreen.screens.map(\.frame)
        return await Task.detached(priority: .userInitiated) {
            MenuBarAccessibilityScanner.scanMenuBarIcons(
                appBundleIdentifier: appBundleIdentifier,
                includeMacBuddy: true
            )
            .contains { icon in
                guard icon.ownerBundleIdentifier == appBundleIdentifier else {
                    return false
                }
                return icon.frame.width >= 8 && frameIntersectsAnyScreen(icon.frame, screenFrames: screenFrames)
            }
        }.value
    }

    private nonisolated static func performCommandDrag(_ plan: MenuBarIconDragPlan) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            performCommandDragSynchronously(plan)
        }.value
    }

    private nonisolated static func performCommandDragSynchronously(_ plan: MenuBarIconDragPlan) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        CGDisplayHideCursor(CGMainDisplayID())
        defer { CGDisplayShowCursor(CGMainDisplayID()) }

        postMouseEvent(.mouseMoved, at: plan.start, source: source)
        Thread.sleep(forTimeInterval: 0.04)
        postMouseEvent(.leftMouseDown, at: plan.start, source: source)
        Thread.sleep(forTimeInterval: 0.04)

        let steps = 16
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: plan.start.x + (plan.end.x - plan.start.x) * progress,
                y: plan.start.y + (plan.end.y - plan.start.y) * progress
            )
            postMouseEvent(.leftMouseDragged, at: point, source: source)
            Thread.sleep(forTimeInterval: 0.015)
        }

        postMouseEvent(.leftMouseUp, at: plan.end, source: source)
        return true
    }

    private nonisolated static func postMouseEvent(_ type: CGEventType, at point: CGPoint, source: CGEventSource) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return
        }
        event.flags = .maskCommand
        event.post(tap: .cghidEventTap)
    }
}

private nonisolated func frameIntersectsAnyScreen(_ frame: CGRect, screenFrames: [CGRect]) -> Bool {
    screenFrames.contains { screenFrame in
        screenFrame.intersects(frame)
    } || frame.maxX > 0
}
