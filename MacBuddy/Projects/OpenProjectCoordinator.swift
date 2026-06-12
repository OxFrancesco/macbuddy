import AppKit
import Observation
import SwiftUI

/// Owns the hotkey-triggered flow: floating fuzzy search over existing
/// projects → launch the configured terminal in the chosen folder.
@Observable
final class OpenProjectCoordinator {
    private let settings: AppSettings
    private var panel: KeyablePanel?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func promptForProject() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let folder = settings.projectsFolder,
              FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            presentError("Choose a projects folder in MacBuddy's Projects tab first.")
            return
        }
        let projects = ProjectScanner.entries(in: folder)
        guard !projects.isEmpty else {
            presentError("No projects in \(folder.lastPathComponent) yet. Create one first.")
            return
        }
        presentPanel(projects: projects)
    }

    private func presentPanel(projects: [ProjectEntry]) {
        let search = ProjectSearchView(
            projects: projects,
            terminalName: settings.terminal.displayName,
            onSelect: { [weak self] entry in self?.open(entry) },
            onCancel: { [weak self] in self?.dismissPanel() }
        )
        panel = KeyablePanel.present(search) { [weak self] in self?.dismissPanel() }
    }

    private func open(_ entry: ProjectEntry) {
        dismissPanel()
        do {
            try TerminalLauncher.launch(settings.terminal, at: entry.url, command: settings.command)
            ToastPresenter.show(message: "Opening \(entry.name) in \(settings.terminal.displayName)")
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
