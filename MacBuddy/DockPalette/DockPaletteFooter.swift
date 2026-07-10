import SwiftUI

struct DockPaletteFooter: View {
    @Bindable var model: DockPaletteModel
    @State private var isConfirmingApply = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: confirmApply) {
                Label("Apply to Dock", systemImage: "paintbrush")
            }
            .buttonStyle(AmberButtonStyle())
            .fixedSize()
            .disabled(model.isBusy || model.apps.isEmpty || aiNotReady)

            Button("Restore Originals", action: startRestore)
                .buttonStyle(GhostButtonStyle())
                .disabled(model.isBusy || !model.canRestoreOriginalIcons)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }

            Spacer()

            if let status = model.statusMessage {
                Text(status)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isBusy)
        .animation(.easeInOut(duration: 0.2), value: model.statusMessage)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .confirmationDialog("Apply styled icons to your Dock?", isPresented: $isConfirmingApply) {
            Button("Apply", action: startApply)
        } message: {
            Text("This writes custom icons onto the app bundles pinned in your Dock, then restarts the Dock. System apps are skipped. You can undo with Restore Originals.")
        }
    }

    /// In AI mode there's nothing to apply until icons have been generated.
    private var aiNotReady: Bool {
        model.style.isGenerative && (model.aiResults.isEmpty || model.isGeneratingAI)
    }

    private func confirmApply() {
        isConfirmingApply = true
    }

    private func startApply() {
        Task {
            await model.applyToDock()
        }
    }

    private func startRestore() {
        Task {
            await model.restoreOriginalIcons()
        }
    }
}
