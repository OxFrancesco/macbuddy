import SwiftUI

struct DockPaletteView: View {
    @State private var model = DockPaletteModel()

    var body: some View {
        VStack(spacing: 0) {
            DockPaletteControls(model: model)
            if model.needsAppManagementPermission {
                DockPermissionBanner(onOpenSettings: model.openPermissionSettings)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            DockAppGrid(model: model)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            DockPaletteFooter(model: model)
        }
        .task { model.loadIfNeeded() }
        .task { await model.refreshAppliedIconAvailability() }
        .task(id: model.previewKey) { await model.refreshPreviews() }
    }
}

#Preview {
    DockPaletteView()
        .frame(width: 720, height: 500)
}
