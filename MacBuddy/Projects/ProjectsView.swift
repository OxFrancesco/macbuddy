import SwiftUI

struct ProjectsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NewProjectCoordinator.self) private var coordinator
    @State private var isChoosingFolder = false

    private let commandPresets = ["claude", "claude --dangerously-skip-permissions", "codex", "gemini", "opencode"]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Projects folder") {
                LabeledContent("Location") {
                    Text(settings.projectsFolder?.path(percentEncoded: false) ?? "Not set")
                        .foregroundStyle(settings.projectsFolder == nil ? .secondary : .primary)
                        .truncationMode(.middle)
                }
                Button("Choose Folder…", systemImage: "folder", action: chooseFolder)
            }

            Section("Terminal") {
                Picker("Terminal app", selection: $settings.terminal) {
                    ForEach(TerminalApp.allCases) { terminal in
                        Text(terminal.menuTitle).tag(terminal)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Command to run", text: $settings.command, prompt: Text("claude"))
                    Menu("Presets", systemImage: "sparkles") {
                        ForEach(commandPresets, id: \.self) { preset in
                            Button(preset) { usePreset(preset) }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Insert a common harness command")
                }
                Text("Runs inside the new project folder. Leave empty to just open a shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global shortcut") {
                LabeledContent("Create project") {
                    ShortcutRecorderView(hotKey: $settings.hotKey)
                }
                if let error = HotKeyCenter.shared.registrationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let hotKey = settings.hotKey {
                    Text("Press \(hotKey.displayString) in any app to create a new project. MacBuddy must be running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("New Project Now", systemImage: "plus", action: coordinator.promptForNewProject)
                    .disabled(settings.projectsFolder == nil)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder], onCompletion: handleFolderSelection)
    }

    private func chooseFolder() {
        isChoosingFolder = true
    }

    private func usePreset(_ preset: String) {
        settings.command = preset
    }

    private func handleFolderSelection(_ result: Result<URL, Error>) {
        if case .success(let url) = result {
            settings.projectsFolder = url
        }
    }
}

#Preview {
    let settings = AppSettings()
    return ProjectsView()
        .environment(settings)
        .environment(NewProjectCoordinator(settings: settings))
}
