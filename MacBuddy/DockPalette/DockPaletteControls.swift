import SwiftUI

struct DockPaletteControls: View {
    @Bindable var model: DockPaletteModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                SectionLabel("Style")
                Picker("Style", selection: $model.style) {
                    ForEach(IconStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if model.style == .tint {
                    ColorPicker("Tint color", selection: $model.tint, supportsOpacity: false)
                        .labelsHidden()
                }

                if !model.style.isGenerative {
                    Text("INTENSITY")
                        .font(Theme.mono(10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(Theme.textTertiary)
                    Slider(value: $model.intensity, in: 0.2...1)
                        .frame(width: 144)
                        .accessibilityLabel("Intensity")
                }

                Spacer()

                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .help("Reload Dock apps")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            if model.style.isGenerative {
                AIPromptRow(model: model)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.style)
    }
}

/// Prompt + strength + generate controls for the AI style.
private struct AIPromptRow: View {
    @Bindable var model: DockPaletteModel
    @State private var isShowingKeyPopover = false

    var body: some View {
        HStack(spacing: 12) {
            SectionLabel("Prompt")

            TextField("e.g. watermelon style, pixel art, claymation…", text: $model.aiPrompt)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.surfaceRaised, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                .onSubmit(model.generateAIIcons)

            Text("STRENGTH")
                .font(Theme.mono(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textTertiary)
            Slider(value: $model.aiStrength, in: 0.2...0.9)
                .frame(width: 96)
                .accessibilityLabel("Restyle strength")
                .help("Higher = stronger restyle, lower = closer to the original icon")

            Button(action: model.generateAIIcons) {
                if model.isGeneratingAI {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Generating…")
                    }
                } else {
                    Label("Generate", systemImage: "sparkles")
                }
            }
            .buttonStyle(GhostButtonStyle())
            .fixedSize()
            .disabled(model.isGeneratingAI || model.apps.isEmpty)
            .help("Restyles every customizable Dock icon via fal.ai (one request per icon)")

            Button {
                isShowingKeyPopover = true
            } label: {
                Image(systemName: model.falKeyAvailable ? "key.fill" : "key.slash")
                    .foregroundStyle(model.falKeyAvailable ? Theme.phosphorGreen : Theme.alarmRed)
            }
            .buttonStyle(IconButtonStyle())
            .help(model.falKeyAvailable ? "fal.ai API key is set" : "Add your fal.ai API key")
            .popover(isPresented: $isShowingKeyPopover, arrowEdge: .bottom) {
                FalKeyPopover(model: model, isPresented: $isShowingKeyPopover)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}

/// Lets the user paste a fal.ai key. The stored key is never displayed.
private struct FalKeyPopover: View {
    let model: DockPaletteModel
    @Binding var isPresented: Bool
    @State private var draftKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("fal.ai API key")

            SecureField(model.falKeyAvailable ? "Key saved — paste to replace" : "Paste your FAL key…", text: $draftKey)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.surfaceRaised, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                .onSubmit(saveKey)

            HStack(spacing: 8) {
                Button("Save", action: saveKey)
                    .buttonStyle(GhostButtonStyle())
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if FalKeyStore.hasStoredKey {
                    Button("Remove") {
                        FalKeyStore.delete()
                        model.refreshFalKeyState()
                        isPresented = false
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                Spacer()
            }

            Text("Stored in your login keychain. The FAL_KEY environment variable also works. Get a key at fal.ai/dashboard/keys.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
        .background(Theme.bg)
    }

    private func saveKey() {
        guard FalKeyStore.save(draftKey) else { return }
        draftKey = ""
        model.refreshFalKeyState()
        isPresented = false
    }
}
