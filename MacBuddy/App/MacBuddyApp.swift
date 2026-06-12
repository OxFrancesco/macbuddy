import SwiftUI

@main
struct MacBuddyApp: App {
    @State private var settings: AppSettings
    @State private var coordinator: NewProjectCoordinator

    init() {
        let settings = AppSettings()
        let coordinator = NewProjectCoordinator(settings: settings)
        _settings = State(initialValue: settings)
        _coordinator = State(initialValue: coordinator)
        HotKeyCenter.shared.onHotKey = { coordinator.promptForNewProject() }
        HotKeyCenter.shared.register(settings.hotKey)
    }

    var body: some Scene {
        Window("MacBuddy", id: "main") {
            ContentView()
                .environment(settings)
                .environment(coordinator)
        }
        .defaultSize(width: 780, height: 560)

        MenuBarExtra("MacBuddy", systemImage: "wrench.and.screwdriver.fill") {
            MenuBarContent()
                .environment(settings)
                .environment(coordinator)
        }
    }
}
