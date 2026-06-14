import AppKit

@MainActor
final class MenuBarCurtainController {
    private var panels: [NSPanel] = []

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    func show(over axFrames: [CGRect]) {
        let frames = mergedFrames(
            axFrames.compactMap(convertAXFrameToScreenFrame)
        )

        guard !frames.isEmpty else {
            hide()
            return
        }

        while panels.count < frames.count {
            panels.append(makePanel())
        }
        while panels.count > frames.count {
            panels.removeLast().orderOut(nil)
        }

        for (panel, frame) in zip(panels, frames) {
            panel.setFrame(frame, display: true)
            panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false

        let visualEffectView = NSVisualEffectView()
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .menu
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.92)
            .cgColor
        panel.contentView = visualEffectView
        return panel
    }

    private func convertAXFrameToScreenFrame(_ axFrame: CGRect) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { screen in
            axFrame.midX >= screen.frame.minX && axFrame.midX <= screen.frame.maxX
        }) else {
            return nil
        }

        let y = screen.frame.maxY - axFrame.maxY
        return CGRect(
            x: axFrame.minX - 2,
            y: y,
            width: axFrame.width + 4,
            height: max(axFrame.height, NSStatusBar.system.thickness)
        )
    }

    private func mergedFrames(_ frames: [CGRect]) -> [CGRect] {
        let sortedFrames = frames
            .map { $0.insetBy(dx: -3, dy: 0) }
            .sorted { lhs, rhs in
                if lhs.minY == rhs.minY {
                    return lhs.minX < rhs.minX
                }
                return lhs.minY < rhs.minY
            }

        return sortedFrames.reduce(into: [CGRect]()) { result, frame in
            guard let last = result.last else {
                result.append(frame)
                return
            }
            if last.intersects(frame) || abs(last.maxX - frame.minX) <= 8 {
                result[result.count - 1] = last.union(frame)
            } else {
                result.append(frame)
            }
        }
    }
}
