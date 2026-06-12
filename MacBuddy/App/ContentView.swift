import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedTab = AppTab.projects

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Projects", systemImage: "folder.badge.plus", value: .projects) {
                ProjectsView()
            }
            Tab("Dock Palette", systemImage: "paintpalette", value: .dockPalette) {
                DockPaletteView()
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .onChange(of: settings.hotKey) {
            HotKeyCenter.shared.register(settings.hotKey)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .environment(NewProjectCoordinator(settings: AppSettings()))
}
