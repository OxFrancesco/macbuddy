import SwiftUI

struct DockPaletteControls: View {
    @Bindable var model: DockPaletteModel

    var body: some View {
        HStack(spacing: 16) {
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

            Text("Intensity")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $model.intensity, in: 0.2...1)
                .frame(width: 144)
                .accessibilityLabel("Intensity")

            Spacer()

            Button("Reload Dock apps", systemImage: "arrow.clockwise", action: model.reload)
                .labelStyle(.iconOnly)
                .help("Reload Dock apps")
        }
        .padding(16)
    }
}
