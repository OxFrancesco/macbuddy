import SwiftUI

struct DockPaletteFooter: View {
    @Bindable var model: DockPaletteModel
    @State private var isConfirmingApply = false

    var body: some View {
        HStack(spacing: 16) {
            Button("Apply to Dock", systemImage: "paintbrush", action: confirmApply)
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.apps.isEmpty)

            Button("Restore Originals", action: model.restoreOriginalIcons)
                .disabled(model.isBusy || model.styledPaths.isEmpty)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }

            Spacer()

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isBusy)
        .animation(.easeInOut(duration: 0.2), value: model.statusMessage)
        .padding(16)
        .confirmationDialog("Apply styled icons to your Dock?", isPresented: $isConfirmingApply) {
            Button("Apply", action: startApply)
        } message: {
            Text("This writes custom icons onto the app bundles pinned in your Dock, then restarts the Dock. System apps are skipped. You can undo with Restore Originals.")
        }
    }

    private func confirmApply() {
        isConfirmingApply = true
    }

    private func startApply() {
        Task {
            await model.applyToDock()
        }
    }
}
