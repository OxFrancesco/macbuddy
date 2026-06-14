import AppKit

@MainActor
final class MenuBarAnchorController {
    private enum Constants {
        static let autosaveName = "dev.francescooddo.macbuddy.menu-bar-boundary"
        static let revealedLength: CGFloat = 14
    }

    private var statusItem: NSStatusItem?
    private let curtainController = MenuBarCurtainController()
    private(set) var hiddenItemsRevealed = true

    func installIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: Constants.revealedLength)
        item.autosaveName = Constants.autosaveName
        item.isVisible = true
        item.button?.title = ""
        item.button?.toolTip = "MacBuddy hidden icon boundary"
        item.button?.isEnabled = false
        item.button?.setAccessibilityElement(false)
        statusItem = item
    }

    func setHiddenItemsRevealed(_ revealed: Bool) {
        installIfNeeded()
        hiddenItemsRevealed = revealed
        statusItem?.length = revealed ? Constants.revealedLength : collapsedLength()
        if !revealed {
            scheduleCollapsedLengthRefresh()
        } else {
            curtainController.hide()
        }
    }

    func updateHiddenItemFrames(_ frames: [CGRect]) {
        if hiddenItemsRevealed {
            curtainController.hide()
        } else {
            curtainController.show(over: frames)
        }
    }

    var separatorFrame: CGRect? {
        guard let button = statusItem?.button, let window = button.window else {
            return nil
        }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    private func collapsedLength() -> CGFloat {
        MenuBarAnchorLayout.collapsedLength(
            separatorFrame: separatorFrame,
            screenFrame: screenContainingSeparator()?.frame
        )
    }

    private func scheduleCollapsedLengthRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !hiddenItemsRevealed else { return }
            statusItem?.length = collapsedLength()
        }
    }

    private func screenContainingSeparator() -> NSScreen? {
        guard let separatorFrame else {
            return NSScreen.main
        }
        let point = CGPoint(x: separatorFrame.midX, y: separatorFrame.midY)
        return NSScreen.screens.first { screen in
            screen.frame.contains(point) || screen.frame.intersects(separatorFrame)
        } ?? NSScreen.main
    }
}
