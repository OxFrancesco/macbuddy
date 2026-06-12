import AppKit
import Observation
import SwiftUI

/// Owns the hotkey-triggered flow: floating name prompt → create folder →
/// launch the configured terminal with the configured command.
@Observable
final class NewProjectCoordinator {
    private let settings: AppSettings
    private var panel: KeyablePanel?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func promptForNewProject() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let folder = settings.projectsFolder,
              FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            presentError("Choose a projects folder in MacBuddy's Projects tab first.")
            return
        }
        presentPanel(for: folder)
    }

    private func presentPanel(for folder: URL) {
        let prompt = NewProjectPromptView(
            folder: folder,
            suggestedName: ProjectNamer.suggestedName(in: folder),
            onSubmit: { [weak self] name in self?.createProject(named: name, in: folder) },
            onCancel: { [weak self] in self?.dismissPanel() }
        )
        let hosting = NSHostingView(rootView: prompt)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = KeyablePanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.onCancel = { [weak self] in self?.dismissPanel() }
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        position(panel, size: hosting.frame.size)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(hosting)
        self.panel = panel
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.62
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func createProject(named name: String, in folder: URL) {
        dismissPanel()
        do {
            let projectURL = try ProjectNamer.createProject(named: name, in: folder)
            try TerminalLauncher.launch(settings.terminal, at: projectURL, command: settings.command)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func dismissPanel() {
        panel?.close()
        panel = nil
    }

    private func presentError(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "MacBuddy"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
