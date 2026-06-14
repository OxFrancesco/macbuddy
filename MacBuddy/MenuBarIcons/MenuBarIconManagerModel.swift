import Foundation
import Observation

@Observable
final class MenuBarIconManagerModel {
    private let store: MenuBarIconStore
    private let accessibilityService: MenuBarAccessibilityService
    private let anchorController: MenuBarAnchorController
    private let mover: MenuBarIconMover
    private let appBundleIdentifier = Bundle.main.bundleIdentifier
    private var hasStarted = false
    private var refreshTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?

    private(set) var icons: [MenuBarIconSnapshot] = []
    private(set) var isAccessibilityTrusted = false
    private(set) var isBusy = false
    private(set) var isScanning = false
    private(set) var movingIconID: String?
    private(set) var statusMessage: String?
    private(set) var hiddenItemsRevealed = true

    init(
        store: MenuBarIconStore = MenuBarIconStore(),
        accessibilityService: MenuBarAccessibilityService = MenuBarAccessibilityService(),
        anchorController: MenuBarAnchorController = MenuBarAnchorController()
    ) {
        self.store = store
        self.accessibilityService = accessibilityService
        self.anchorController = anchorController
        mover = MenuBarIconMover(
            accessibilityService: accessibilityService,
            anchorController: anchorController
        )
        hiddenItemsRevealed = store.hiddenItemsRevealed
    }

    var keepIcons: [MenuBarIconSnapshot] {
        icons.filter { $0.zone == .keep || $0.zone == .system }
    }

    var hiddenIcons: [MenuBarIconSnapshot] {
        icons.filter { $0.zone == .hidden }
    }

    var hiddenIconCount: Int {
        store.hiddenIconIDs.count
    }

    func prepareMenuBarAnchor() {
        anchorController.installIfNeeded()
        anchorController.setHiddenItemsRevealed(store.hiddenItemsRevealed)
        hiddenItemsRevealed = store.hiddenItemsRevealed
    }

    func ensureStarted() {
        guard !hasStarted else { return }
        prepareMenuBarAnchor()
        hasStarted = true
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        anchorController.installIfNeeded()
        isAccessibilityTrusted = accessibilityService.isTrusted
        guard isAccessibilityTrusted else {
            icons = []
            isScanning = false
            anchorController.updateHiddenItemFrames([])
            statusMessage = "Accessibility access is required to read menu bar icons."
            return
        }

        isScanning = true
        statusMessage = "Scanning menu bar icons..."

        let separatorFrame = anchorController.separatorFrame
        let hiddenIDs = store.hiddenIconIDs
        let appBundleIdentifier = appBundleIdentifier
        refreshTask = Task { [weak self] in
            let scannedIcons = await Task.detached(priority: .userInitiated) {
                MenuBarAccessibilityScanner.scanMenuBarIcons(
                    appBundleIdentifier: appBundleIdentifier
                )
            }.value
            guard !Task.isCancelled else { return }
            var classifiedIcons = MenuBarIconZoneClassifier.classify(
                scannedIcons,
                separatorFrame: separatorFrame,
                hiddenIDs: hiddenIDs,
                appBundleIdentifier: appBundleIdentifier
            )
            if self?.hiddenItemsRevealed == false {
                classifiedIcons = classifiedIcons.map { icon in
                    guard hiddenIDs.contains(icon.id), !icon.isSystemItem else {
                        return icon
                    }
                    var hiddenIcon = icon
                    hiddenIcon.zone = .hidden
                    return hiddenIcon
                }
            }
            self?.icons = classifiedIcons
            self?.updateHiddenCurtain(for: classifiedIcons)
            self?.isScanning = false
            self?.statusMessage = classifiedIcons.isEmpty ? "No menu bar icons were detected." : nil
        }
    }

    func requestAccessibilityPermission() {
        isAccessibilityTrusted = accessibilityService.requestTrustPrompt()
        refresh()
    }

    func openAccessibilitySettings() {
        accessibilityService.openAccessibilitySettings()
    }

    func openControlCenterSettings() {
        accessibilityService.openControlCenterSettings()
    }

    func revealHidden() {
        ensureStarted()
        store.hiddenItemsRevealed = true
        hiddenItemsRevealed = true
        anchorController.setHiddenItemsRevealed(true)
        anchorController.updateHiddenItemFrames([])
        statusMessage = "Hidden icons are visible."
    }

    func hideHidden() {
        ensureStarted()
        guard hiddenIconCount > 0 else {
            statusMessage = "Move at least one icon to Hidden first."
            return
        }
        store.hiddenItemsRevealed = false
        hiddenItemsRevealed = false
        anchorController.setHiddenItemsRevealed(false)
        updateHiddenCurtain(for: icons)
        statusMessage = "Hidden icons are collapsed."
    }

    func moveToHidden(_ icon: MenuBarIconSnapshot) {
        move(icon, direction: .hidden)
    }

    func moveToKeep(_ icon: MenuBarIconSnapshot) {
        move(icon, direction: .keep)
    }

    func openMenu(for icon: MenuBarIconSnapshot) {
        ensureStarted()
        if icon.zone == .hidden, !hiddenItemsRevealed {
            revealHidden()
        }
        if accessibilityService.activate(icon) {
            statusMessage = "Opened \(icon.displayName)."
        } else {
            statusMessage = "Could not open \(icon.displayName)."
        }
    }

    private func move(_ icon: MenuBarIconSnapshot, direction: MenuBarMoveDirection) {
        ensureStarted()
        guard !isBusy else { return }
        isBusy = true
        movingIconID = icon.id
        refreshTask?.cancel()
        isScanning = false
        statusMessage = "Moving \(icon.displayName)..."

        moveTask?.cancel()
        moveTask = Task { [weak self] in
            guard let self else { return }
            let result = await mover.move(icon: icon, direction: direction)
            guard !Task.isCancelled else { return }

            switch result {
            case .success:
                store.setHidden(direction == .hidden, for: icon.id)
                updateLocalZone(for: icon, direction: direction)
                if direction == .hidden {
                    store.hiddenItemsRevealed = false
                    hiddenItemsRevealed = false
                    anchorController.setHiddenItemsRevealed(false)
                    updateHiddenCurtain(for: icons)
                    statusMessage = "\(icon.displayName) moved to Hidden and collapsed."
                } else {
                    if hiddenIconCount == 0 {
                        store.hiddenItemsRevealed = true
                        hiddenItemsRevealed = true
                        anchorController.setHiddenItemsRevealed(true)
                        anchorController.updateHiddenItemFrames([])
                    } else if !store.hiddenItemsRevealed {
                        hiddenItemsRevealed = false
                        anchorController.setHiddenItemsRevealed(false)
                        updateHiddenCurtain(for: icons)
                    }
                    statusMessage = "\(icon.displayName) moved to Keep."
                }
            case .failure(let error):
                statusMessage = error.localizedDescription
                refresh()
            }
            movingIconID = nil
            isBusy = false
        }
    }

    private func updateLocalZone(
        for icon: MenuBarIconSnapshot,
        direction: MenuBarMoveDirection
    ) {
        guard let index = icons.firstIndex(where: { $0.id == icon.id }) else {
            return
        }
        icons[index].zone = direction == .hidden ? .hidden : .keep
        icons.sort { lhs, rhs in
            if lhs.zone != rhs.zone {
                return lhs.zone.rawValue < rhs.zone.rawValue
            }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    private func updateHiddenCurtain(for icons: [MenuBarIconSnapshot]) {
        guard !hiddenItemsRevealed else {
            anchorController.updateHiddenItemFrames([])
            return
        }
        let hiddenIDs = store.hiddenIconIDs
        let hiddenFrames = icons
            .filter { hiddenIDs.contains($0.id) && !$0.isSystemItem }
            .map(\.frame)
        anchorController.updateHiddenItemFrames(hiddenFrames)
    }
}
