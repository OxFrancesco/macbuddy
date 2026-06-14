import SwiftUI

struct DockAppCell: View {
    let app: DockApp
    let preview: IconBitmap?
    var isGenerating = false
    /// Present when the preview is a kept AI generation — shows the badge and
    /// the hover ✗ that discards it.
    var onDiscard: (() -> Void)?
    /// Present in AI mode for customizable apps — hover ↻ that regenerates
    /// just this icon.
    var onRegenerate: (() -> Void)?
    @State private var isHovering = false

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
                    GeneratingOverlay()
                        .transition(.opacity)
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
                } else if onDiscard != nil, !isGenerating {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                        .padding(4)
                        .background(.black.opacity(0.7), in: .circle)
                        .transition(.opacity)
                        .help("AI-generated icon — will be applied")
                }
            }
            .overlay(alignment: .topTrailing) {
                if let onDiscard, isHovering, !isGenerating {
                    hoverButton(systemImage: "xmark", action: onDiscard)
                        .offset(x: 7, y: -7)
                        .help("Discard this generated icon")
                }
            }
            .overlay(alignment: .topLeading) {
                if let onRegenerate, isHovering, !isGenerating {
                    hoverButton(systemImage: "arrow.clockwise", action: onRegenerate)
                        .offset(x: -7, y: -7)
                        .help("Regenerate just this icon")
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
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

    private func hoverButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(5)
                .background(.black.opacity(0.8), in: .circle)
                .overlay(Circle().strokeBorder(Theme.strokeBright))
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private var baseImage: Image {
        if let source = app.previewSource {
            Image(decorative: source.image, scale: 2)
        } else {
            Image(systemName: "app.dashed")
        }
    }
}

/// "AI is drawing this one" overlay: dims the icon hard, sweeps a bright amber
/// scan line down it, pulses an amber glow border, and breathes a glowing
/// sparkle in the middle. Falls back to a static treatment when Reduce Motion
/// is on.
private struct GeneratingOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 14)
    private let scanPeriod = 1.1
    private let pulsePeriod = 1.5

    var body: some View {
        ZStack {
            shape.fill(.black.opacity(0.62))
            if reduceMotion {
                glowBorder(opacity: 0.9)
                sparkle(opacity: 1, scale: 1)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let pulse = (sin(t * 2 * .pi / pulsePeriod) + 1) / 2
                    ZStack {
                        scanBeam(phase: (t / scanPeriod).truncatingRemainder(dividingBy: 1))
                        glowBorder(opacity: 0.45 + 0.55 * pulse)
                        sparkle(opacity: 0.7 + 0.3 * pulse, scale: 0.9 + 0.25 * pulse)
                    }
                }
            }
        }
        .accessibilityLabel("Generating icon")
    }

    private func scanBeam(phase: Double) -> some View {
        GeometryReader { proxy in
            let beamHeight = proxy.size.height * 0.5
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Theme.amber.opacity(0.12), location: 0.55),
                    .init(color: Theme.amber.opacity(0.95), location: 0.85),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: proxy.size.width, height: beamHeight)
            .offset(y: phase * (proxy.size.height + beamHeight) - beamHeight)
            .blendMode(.plusLighter)
        }
        .clipShape(shape)
    }

    private func glowBorder(opacity: Double) -> some View {
        shape
            .strokeBorder(Theme.amber.opacity(opacity), lineWidth: 2)
            .shadow(color: Theme.amber.opacity(opacity * 0.8), radius: 5)
    }

    private func sparkle(opacity: Double, scale: Double) -> some View {
        Image(systemName: "sparkles")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.amber)
            .opacity(opacity)
            .scaleEffect(scale)
            .shadow(color: Theme.amber.opacity(0.8), radius: 6)
    }
}
