import SwiftUI

struct DockAppCell: View {
    let app: DockApp
    let preview: IconBitmap?

    var body: some View {
        VStack(spacing: 8) {
            iconImage
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)
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
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(app.isCustomizable ? 1 : 0.45)
        .help(app.isCustomizable ? app.path : "\(app.name) is a system app — its icon can't be changed.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.name)
    }

    private var iconImage: Image {
        if let preview {
            Image(decorative: preview.image, scale: 2)
        } else if let source = app.previewSource {
            Image(decorative: source.image, scale: 2)
        } else {
            Image(systemName: "app.dashed")
        }
    }
}
