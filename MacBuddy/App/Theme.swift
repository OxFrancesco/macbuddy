import SwiftUI

/// MacBuddy's "terminal instrument" design language: warm charcoal layers,
/// phosphor-amber accents, monospaced chrome. Always dark — it lives next to
/// your terminal.
enum Theme {
    // MARK: Palette

    static let bg = Color(red: 0.051, green: 0.051, blue: 0.063)
    static let surface = Color(red: 0.090, green: 0.090, blue: 0.110)
    static let surfaceRaised = Color(red: 0.128, green: 0.128, blue: 0.152)
    static let terminalBlack = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let stroke = Color.white.opacity(0.07)
    static let strokeBright = Color.white.opacity(0.14)

    static let amber = Color(red: 1.0, green: 0.706, blue: 0.329)
    static let amberDeep = Color(red: 0.852, green: 0.494, blue: 0.164)
    static let phosphorGreen = Color(red: 0.486, green: 0.890, blue: 0.545)
    static let alarmRed = Color(red: 1.0, green: 0.451, blue: 0.420)

    static let textPrimary = Color(red: 0.925, green: 0.925, blue: 0.945)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.32)

    // MARK: Type

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Window background

/// Charcoal base with a faint dot grid and an amber glow bleeding in from the
/// top — the room the instrument sits in.
struct ThemeBackground: View {
    var body: some View {
        ZStack {
            Theme.bg
            Canvas { context, size in
                let step: CGFloat = 22
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        let dot = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                        context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.035)))
                        x += step
                    }
                    y += step
                }
            }
            RadialGradient(
                colors: [Theme.amber.opacity(0.07), .clear],
                center: .init(x: 0.25, y: -0.1),
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Card chrome

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(Theme.surface.opacity(0.85), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }
}

extension View {
    func themeCard() -> some View {
        modifier(CardModifier())
    }
}

/// Dark glass chrome for the floating hotkey panels.
struct PanelGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 16).fill(Theme.bg.opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.strokeBright))
            }
    }
}

extension View {
    func panelGlass() -> some View {
        modifier(PanelGlassModifier())
    }
}

/// `// SECTION` label — tracked-out mono caps with an amber comment marker.
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("//")
                .foregroundStyle(Theme.amber.opacity(0.8))
            Text(title)
                .foregroundStyle(Theme.textTertiary)
                .tracking(2.2)
        }
        .font(Theme.mono(10, weight: .semibold))
        .textCase(.uppercase)
    }
}

// MARK: - Keycaps

/// A hotkey rendered as physical keycaps.
struct KeycapRow: View {
    let labels: [String]

    init(_ spec: HotKeySpec) {
        labels = spec.keycapLabels
    }

    init(labels: [String]) {
        self.labels = labels
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Keycap(label)
            }
        }
    }
}

struct Keycap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(Theme.mono(11, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(minWidth: 13)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.surfaceRaised)
                    .shadow(color: .black.opacity(0.55), radius: 0, y: 1.5)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.strokeBright))
    }
}

// MARK: - Blinking cursor

struct BlinkingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOn = true

    var body: some View {
        Rectangle()
            .fill(Theme.amber)
            .frame(width: 7, height: 14)
            .opacity(isOn ? 1 : 0.1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    isOn = false
                }
            }
    }
}

// MARK: - Buttons

/// Filled phosphor-amber action button.
struct AmberButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, weight: .bold))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Theme.amber, Theme.amberDeep],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: .rect(cornerRadius: 8)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Quiet outlined button for secondary actions.
struct GhostButtonStyle: ButtonStyle {
    var fillsWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, weight: .semibold))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.1 : 0.04),
                in: .rect(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.strokeBright))
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Small borderless icon button.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 26, height: 26)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.1 : 0),
                in: .rect(cornerRadius: 6)
            )
            .contentShape(.rect)
    }
}

// MARK: - Entrance animation

/// Staggered rise-and-fade used for the launch reveal.
struct EntranceModifier: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : 12)
            .onAppear {
                withAnimation(.spring(duration: 0.55).delay(delay)) {
                    hasAppeared = true
                }
            }
    }
}

extension View {
    func entrance(_ delay: Double) -> some View {
        modifier(EntranceModifier(delay: delay))
    }
}
