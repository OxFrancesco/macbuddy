import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedTab = AppTab.projects

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(selectedTab: $selectedTab)
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
            Group {
                switch selectedTab {
                case .projects:
                    ProjectsView()
                case .dockPalette:
                    DockPaletteView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.18), value: selectedTab)
        .background(ThemeBackground())
        .tint(Theme.amber)
        .preferredColorScheme(.dark)
        .frame(minWidth: 760, minHeight: 540)
        .onChange(of: settings.hotKey) {
            HotKeyCenter.shared.register(settings.hotKey, for: .newProject)
        }
        .onChange(of: settings.openProjectHotKey) {
            HotKeyCenter.shared.register(settings.openProjectHotKey, for: .openProject)
        }
    }
}

/// Custom title-bar replacement: wordmark on the left, a quiet two-state
/// switch on the right. Nothing else.
private struct HeaderBar: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        HStack(spacing: 16) {
            wordmark
            Spacer()
            TabSwitch(selectedTab: $selectedTab)
        }
        .padding(.horizontal, 24)
        .frame(height: 48)
        .gesture(WindowDragGesture())
    }

    private var wordmark: some View {
        HStack(spacing: 2) {
            Text("MACBUDDY")
                .font(Theme.mono(13, weight: .bold))
                .tracking(3)
                .foregroundStyle(Theme.textPrimary)
            BlinkingCursor()
                .frame(width: 7, height: 13)
        }
        .accessibilityLabel("MacBuddy")
    }
}

/// Bare text switch — the active view carries a sliding amber underline.
private struct TabSwitch: View {
    @Binding var selectedTab: AppTab
    @Namespace private var indicator

    private let tabs: [(tab: AppTab, title: String)] = [
        (.projects, "PROJECTS"),
        (.dockPalette, "DOCK"),
    ]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(tabs, id: \.tab) { item in
                SwitchLabel(
                    title: item.title,
                    isActive: selectedTab == item.tab,
                    namespace: indicator
                ) {
                    selectedTab = item.tab
                }
            }
        }
        .animation(.spring(duration: 0.3), value: selectedTab)
    }
}

private struct SwitchLabel: View {
    let title: String
    let isActive: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(labelColor)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    if isActive {
                        Capsule()
                            .fill(Theme.amber)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "tab-underline", in: namespace)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var labelColor: Color {
        if isActive { return Theme.textPrimary }
        return isHovered ? Theme.textSecondary : Theme.textTertiary
    }
}

#Preview {
    let settings = AppSettings()
    return ContentView()
        .environment(settings)
        .environment(NewProjectCoordinator(settings: settings))
        .environment(OpenProjectCoordinator(settings: settings))
}
