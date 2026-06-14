import SwiftUI

struct MenuBarIconsView: View {
    @Environment(MenuBarIconManagerModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            MenuBarIconControls(model: model)
            if !model.isAccessibilityTrusted {
                MenuBarAccessibilityBanner(
                    onPrompt: model.requestAccessibilityPermission,
                    onOpenSettings: model.openAccessibilitySettings
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let statusMessage = model.statusMessage {
                        StatusPill(message: statusMessage)
                    }
                    MenuBarIconSection(
                        title: "Keep",
                        emptyText: "No visible third-party icons detected.",
                        icons: model.keepIcons,
                        model: model
                    )
                    MenuBarIconSection(
                        title: "Hidden",
                        emptyText: "Choose icons from Keep to hide them here.",
                        icons: model.hiddenIcons,
                        model: model
                    )
                }
                .padding(24)
            }
        }
        .task { model.ensureStarted() }
    }
}

private struct MenuBarIconControls: View {
    let model: MenuBarIconManagerModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("menu bar")
                Text("Choose which third-party status items stay visible.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.amber)
                    Text("SCANNING")
                        .font(Theme.mono(10, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.textSecondary)
                }
                .transition(.opacity)
            }
            Button(action: model.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(model.isBusy || model.isScanning)

            Button(action: toggleHiddenVisibility) {
                Label(hiddenToggleTitle, systemImage: hiddenToggleSymbol)
            }
            .buttonStyle(AmberButtonStyle())
            .disabled(model.isBusy || model.isScanning || model.hiddenIconCount == 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var hiddenToggleTitle: String {
        model.hiddenItemsRevealed ? "Collapse Hidden Icons" : "Reveal Hidden Icons"
    }

    private var hiddenToggleSymbol: String {
        model.hiddenItemsRevealed ? "eye.slash" : "eye"
    }

    private func toggleHiddenVisibility() {
        if model.hiddenItemsRevealed {
            model.hideHidden()
        } else {
            model.revealHidden()
        }
    }
}

private struct MenuBarAccessibilityBanner: View {
    let onPrompt: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "figure.run.square.stack.fill")
                .font(.title3)
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacBuddy needs Accessibility access")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                Text("Enable MacBuddy under System Settings → Privacy & Security → Accessibility to read and move menu bar icons.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Ask macOS", action: onPrompt)
                .buttonStyle(GhostButtonStyle())
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(GhostButtonStyle())
        }
        .padding(16)
        .background(Theme.amber.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.amber.opacity(0.25)))
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}

private struct MenuBarIconSection: View {
    let title: String
    let emptyText: String
    let icons: [MenuBarIconSnapshot]
    let model: MenuBarIconManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionLabel(title)
                Text("\(icons.count)")
                    .font(Theme.mono(10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.surfaceRaised, in: .capsule)
            }

            if icons.isEmpty {
                Text(emptyText)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Theme.surface.opacity(0.7), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(icons) { icon in
                        MenuBarIconRow(icon: icon, model: model)
                    }
                }
            }
        }
    }
}

private struct MenuBarIconRow: View {
    let icon: MenuBarIconSnapshot
    let model: MenuBarIconManagerModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(icon.isSystemItem ? Theme.textTertiary : Theme.amber)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceRaised, in: .rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text(icon.displayName)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(icon.secondaryText)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if icon.isSystemItem {
                Button(action: model.openControlCenterSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                Button {
                    model.openMenu(for: icon)
                } label: {
                    Label("Open", systemImage: "cursorarrow.click.2")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.isBusy || model.isScanning)

                if model.movingIconID == icon.id {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.amber)
                        Text("MOVING")
                            .font(Theme.mono(10, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: 94, alignment: .center)
                } else {
                    zoneButton
                }
            }
        }
        .padding(12)
        .background(Theme.surface.opacity(0.82), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
        .help(helpText)
    }

    private var iconSymbol: String {
        if icon.isSystemItem {
            "apple.logo"
        } else if icon.zone == .hidden {
            "eye.slash.fill"
        } else {
            "menubar.rectangle"
        }
    }

    private var zoneActionTitle: String {
        icon.zone == .hidden ? "Keep" : "Hide"
    }

    private var zoneActionSymbol: String {
        icon.zone == .hidden ? "pin.fill" : "eye.slash"
    }

    @ViewBuilder
    private var zoneButton: some View {
        if icon.zone == .hidden {
            Button(action: zoneAction) {
                Label(zoneActionTitle, systemImage: zoneActionSymbol)
            }
            .buttonStyle(AmberButtonStyle())
            .disabled(model.isBusy || model.isScanning)
        } else {
            Button(action: zoneAction) {
                Label(zoneActionTitle, systemImage: zoneActionSymbol)
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(model.isBusy || model.isScanning)
        }
    }

    private var helpText: String {
        icon.isSystemItem
            ? "Apple menu bar items are managed by System Settings."
            : "Command-drag this status item between MacBuddy's menu bar sections."
    }

    private func zoneAction() {
        if icon.zone == .hidden {
            model.moveToKeep(icon)
        } else {
            model.moveToHidden(icon)
        }
    }
}

private struct StatusPill: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            if message.localizedCaseInsensitiveContains("scanning")
                || message.localizedCaseInsensitiveContains("moving") {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.amber)
            }
            Text(message)
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surfaceRaised.opacity(0.6), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
    }
}

#Preview {
    let model = MenuBarIconManagerModel()
    return MenuBarIconsView()
        .environment(model)
        .frame(width: 820, height: 540)
}
