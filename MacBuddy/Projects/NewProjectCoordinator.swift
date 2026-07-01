import AppKit
import Observation
import SwiftUI

/// Owns the hotkey-triggered flow: floating name prompt → create folder →
/// launch the configured terminal with the configured command.
@Observable
final class NewProjectCoordinator {
    private let settings: AppSettings
    private var panel: KeyablePanel?
    private var isPreparingPanel = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func promptForNewProject() {
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
            // The existence check and name scan hit the disk; keep them off
            // the main actor so the hotkey never stalls the UI.
            let suggestedName = await Self.suggestedName(in: folder)
            guard let self else { return }
            isPreparingPanel = false
            guard let suggestedName else {
                presentError("Choose a projects folder in MacBuddy's Projects tab first.")
                return
            }
            presentPanel(for: folder, suggestedName: suggestedName)
        }
    }

    /// Returns nil when the folder is missing, so the caller can surface the
    /// "choose a folder first" message.
    @concurrent
    private nonisolated static func suggestedName(in folder: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            return nil
        }
        return ProjectNamer.suggestedName(in: folder)
    }

    private func presentPanel(for folder: URL, suggestedName: String) {
        let prompt = NewProjectPromptView(
            folder: folder,
            suggestedName: suggestedName,
            onSubmit: { [weak self] name in self?.createProject(named: name, in: folder) },
            onCancel: { [weak self] in self?.dismissPanel() }
        )
        panel = KeyablePanel.present(prompt) { [weak self] in self?.dismissPanel() }
    }

    private func createProject(named name: String, in folder: URL) {
        dismissPanel()
        let terminal = settings.terminal
        let command = settings.command
        Task { [weak self] in
            do {
                // mkdir and the terminal launch both do disk and process work;
                // run them on the concurrent executor.
                let projectURL = try await Self.createFolder(named: name, in: folder)
                try await TerminalLauncher.launch(terminal, at: projectURL, command: command)
                ToastPresenter.show(message: "\(name) created — opening \(terminal.displayName)")
            } catch {
                self?.presentError(error.localizedDescription)
            }
        }
    }

    @concurrent
    private nonisolated static func createFolder(named name: String, in folder: URL) async throws -> URL {
        try ProjectNamer.createProject(named: name, in: folder)
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
