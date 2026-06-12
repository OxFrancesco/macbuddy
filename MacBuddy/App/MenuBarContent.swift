import SwiftUI

struct MenuBarContent: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NewProjectCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Project…", action: coordinator.promptForNewProject)
        Button("Open MacBuddy", action: openMainWindow)
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
