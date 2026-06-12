import SwiftUI

struct ToastView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.phosphorGreen)
            Text(message)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Theme.bg.opacity(0.72)))
                .overlay(Capsule().strokeBorder(Theme.strokeBright))
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ToastView(message: "project-3 created — opening Ghostty", systemImage: "checkmark.circle.fill")
        .padding(24)
        .background(ThemeBackground())
}
