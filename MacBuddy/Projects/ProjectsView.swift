import SwiftUI

struct ProjectsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NewProjectCoordinator.self) private var coordinator
    @Environment(OpenProjectCoordinator.self) private var openCoordinator
    @State private var isChoosingFolder = false

    private let commandPresets = ["claude", "claude --dangerously-skip-permissions", "codex", "gemini", "opencode"]

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(spacing: 16) {
                folderBar
                    .entrance(0.05)
                HStack(alignment: .top, spacing: 16) {
                    launchCard(settings: $settings)
                    shortcutsCard(settings: $settings)
                }
                .entrance(0.12)
                actionRow
                    .entrance(0.18)
            }
            .padding(24)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder], onCompletion: handleFolderSelection)
    }

    // MARK: Folder

    /// One slim bar: label, path, chooser. The path color carries the state.
    private var folderBar: some View {
        HStack(spacing: 12) {
            SectionLabel("Folder")
            Text(settings.projectsFolder?.path(percentEncoded: false) ?? "not set")
                .font(Theme.mono(12))
                .foregroundStyle(settings.projectsFolder == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button("Choose") { isChoosingFolder = true }
                .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.85), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }

    // MARK: Launch

    private func launchCard(settings: Bindable<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Launch")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(TerminalApp.allCases) { terminal in
                    TerminalPill(
                        terminal: terminal,
                        isSelected: settings.wrappedValue.terminal == terminal,
                        action: { settings.wrappedValue.terminal = terminal }
                    )
                }
            }
            HStack(spacing: 8) {
                Text("$")
                    .font(Theme.mono(13, weight: .bold))
                    .foregroundStyle(Theme.amber)
                TextField("claude", text: settings.command)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.textPrimary)
                Menu {
                    ForEach(commandPresets, id: \.self) { preset in
                        Button(preset) { settings.wrappedValue.command = preset }
                    }
                } label: {
                    Image(systemName: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.textSecondary)
                .help("Insert a common harness command — it runs inside the new project folder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.terminalBlack, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    // MARK: Shortcuts

    private func shortcutsCard(settings: Bindable<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Global shortcuts")
            shortcutRow(title: "Create project", hotKey: settings.hotKey, action: .newProject)
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
            shortcutRow(title: "Open project", hotKey: settings.openProjectHotKey, action: .openProject)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    @ViewBuilder
    private func shortcutRow(title: String, hotKey: Binding<HotKeySpec?>, action: HotKeyAction) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            ShortcutRecorderView(hotKey: hotKey)
        }
        if let error = HotKeyCenter.shared.registrationError(for: action) {
            Text(error)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.alarmRed)
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 16) {
            Button {
                coordinator.promptForNewProject()
            } label: {
                Label("New project", systemImage: "plus")
            }
            .buttonStyle(AmberButtonStyle())
            Button {
                openCoordinator.promptForProject()
            } label: {
                Label("Open project", systemImage: "magnifyingglass")
            }
            .buttonStyle(GhostButtonStyle(fillsWidth: true))
        }
        .disabled(settings.projectsFolder == nil)
    }

    private func handleFolderSelection(_ result: Result<URL, Error>) {
        if case .success(let url) = result {
            settings.projectsFolder = url
        }
    }
}

// MARK: - Terminal pill

private struct TerminalPill: View {
    let terminal: TerminalApp
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(terminal.displayName)
                .font(Theme.mono(11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(pillForeground)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Theme.amber.opacity(0.12) : Color.white.opacity(0.03),
                    in: .rect(cornerRadius: 7)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isSelected ? Theme.amber.opacity(0.4) : Theme.stroke)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(terminal.isInstalled ? terminal.displayName : "\(terminal.displayName) is not installed")
    }

    private var pillForeground: Color {
        if isSelected { return Theme.amber }
        return terminal.isInstalled ? Theme.textSecondary : Theme.textTertiary.opacity(0.6)
    }
}

#Preview {
    let settings = AppSettings()
    return ProjectsView()
        .environment(settings)
        .environment(NewProjectCoordinator(settings: settings))
        .environment(OpenProjectCoordinator(settings: settings))
        .background(ThemeBackground())
        .preferredColorScheme(.dark)
        .frame(width: 820, height: 600)
}
