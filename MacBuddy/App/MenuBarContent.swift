import SwiftUI

struct MenuBarContent: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NewProjectCoordinator.self) private var coordinator
    @Environment(OpenProjectCoordinator.self) private var openCoordinator
    @Environment(MenuBarIconManagerModel.self) private var menuBarIconModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Project…", action: coordinator.promptForNewProject)
        Button("Open Project…", action: openCoordinator.promptForProject)
        Button("Open MacBuddy", action: openMainWindow)
        Divider()
        Button("Reveal Hidden Icons", action: menuBarIconModel.revealHidden)
        Button("Hide Hidden Icons", action: menuBarIconModel.hideHidden)
        Divider()
        Button("Quit MacBuddy", action: quit)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private func quit() {
        NSApp.terminate(nil)
    }
}
