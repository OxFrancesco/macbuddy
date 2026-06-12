import SwiftUI

struct DockPaletteView: View {
    @State private var model = DockPaletteModel()

    var body: some View {
        VStack(spacing: 0) {
            DockPaletteControls(model: model)
            Divider()
            DockAppGrid(model: model)
            Divider()
            DockPaletteFooter(model: model)
        }
        .task { model.loadIfNeeded() }
        .task(id: model.previewKey) { await model.refreshPreviews() }
    }
}

#Preview {
    DockPaletteView()
        .frame(width: 720, height: 500)
}
