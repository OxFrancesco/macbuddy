import AppKit
import Observation
import SwiftUI

/// Owns the hotkey-triggered flow: floating fuzzy search over existing
/// projects → launch the configured terminal in the chosen folder.
@Observable
final class OpenProjectCoordinator {
    private let settings: AppSettings
    private var panel: KeyablePanel?
    private var isPreparingPanel = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func promptForProject() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard !isPreparingPanel else { return }
        guard let folder = settings.projectsFolder else {
            presentError("Choose a projects folder in MacBuddy's Projects tab first.")
            return
        }
        isPreparingPanel = true
        Task { [weak self] in
            // The existence check and directory scan hit the disk; keep them
            // off the main actor so the hotkey never stalls the UI.
            let projects = await Self.scanProjects(in: folder)
            guard let self else { return }
            isPreparingPanel = false
            guard let projects else {
                presentError("Choose a projects folder in MacBuddy's Projects tab first.")
                return
            }
            guard !projects.isEmpty else {
                presentError("No projects in \(folder.lastPathComponent) yet. Create one first.")
                return
            }
            presentPanel(projects: projects)
        }
    }

    /// Returns nil when the folder is missing, so the caller can keep the
    /// "choose a folder first" message distinct from "no projects yet".
    @concurrent
    private nonisolated static func scanProjects(in folder: URL) async -> [ProjectEntry]? {
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            return nil
        }
        return ProjectScanner.entries(in: folder)
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
        let terminal = settings.terminal
        let command = settings.command
        Task { [weak self] in
            do {
                try await TerminalLauncher.launch(terminal, at: entry.url, command: command)
                ToastPresenter.show(message: "Opening \(entry.name) in \(terminal.displayName)")
            } catch {
                self?.presentError(error.localizedDescription)
            }
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
