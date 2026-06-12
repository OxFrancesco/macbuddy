import SwiftUI

@main
struct MacBuddyApp: App {
    @State private var settings: AppSettings
    @State private var coordinator: NewProjectCoordinator
    @State private var openCoordinator: OpenProjectCoordinator

    init() {
        let settings = AppSettings()
        let coordinator = NewProjectCoordinator(settings: settings)
        let openCoordinator = OpenProjectCoordinator(settings: settings)
        _settings = State(initialValue: settings)
        _coordinator = State(initialValue: coordinator)
        _openCoordinator = State(initialValue: openCoordinator)
        HotKeyCenter.shared.onHotKey = { action in
            switch action {
            case .newProject: coordinator.promptForNewProject()
            case .openProject: openCoordinator.promptForProject()
            }
        }
        HotKeyCenter.shared.register(settings.hotKey, for: .newProject)
        HotKeyCenter.shared.register(settings.openProjectHotKey, for: .openProject)
    }

    var body: some Scene {
        Window("MacBuddy", id: "main") {
            ContentView()
                .environment(settings)
                .environment(coordinator)
                .environment(openCoordinator)
        }
        .defaultSize(width: 820, height: 600)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("MacBuddy", systemImage: "wrench.and.screwdriver.fill") {
            MenuBarContent()
                .environment(settings)
                .environment(coordinator)
                .environment(openCoordinator)
        }
    }
}
