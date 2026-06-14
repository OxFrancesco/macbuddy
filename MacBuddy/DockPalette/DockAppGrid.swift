import SwiftUI

struct DockAppGrid: View {
    let model: DockPaletteModel

    var body: some View {
        if model.apps.isEmpty {
            ContentUnavailableView {
                Label("No Dock apps", systemImage: "dock.rectangle")
            } description: {
                Text("MacBuddy couldn't read your Dock layout.")
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 16)], spacing: 24) {
                    ForEach(model.apps) { app in
                        DockAppCell(
                            app: app,
                            preview: model.previews[app.id],
                            isGenerating: model.generatingPaths.contains(app.path),
                            onDiscard: model.style == .ai && model.aiResults[app.path] != nil
                                ? { model.discardAIResult(forAppPath: app.path) }
                                : nil,
                            onRegenerate: model.style == .ai && app.isCustomizable
                                ? { model.regenerateAIIcon(forAppPath: app.path) }
                                : nil
                        )
                    }
                }
                .padding(24)
            }
        }
    }
}
