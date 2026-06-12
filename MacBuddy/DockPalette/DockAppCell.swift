import SwiftUI

struct DockAppCell: View {
    let app: DockApp
    let preview: IconBitmap?
    var isGenerating = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                baseImage
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                if let preview {
                    Image(decorative: preview.image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .id(ObjectIdentifier(preview.image))
                        .transition(.opacity)
                }
                if isGenerating {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.black.opacity(0.45))
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 64, height: 64)
            .animation(.easeInOut(duration: 0.2), value: isGenerating)
            .overlay(alignment: .bottomTrailing) {
                if !app.isCustomizable {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(.thickMaterial, in: .circle)
                }
            }
            Text(app.name)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(app.isCustomizable ? 1 : 0.45)
        .help(app.isCustomizable ? app.path : "\(app.name) is a system app — its icon can't be changed.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.name)
    }

    private var baseImage: Image {
        if let source = app.previewSource {
            Image(decorative: source.image, scale: 2)
        } else {
            Image(systemName: "app.dashed")
        }
    }
}
