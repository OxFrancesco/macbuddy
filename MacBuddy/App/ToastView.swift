import SwiftUI

struct ToastView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.green)
            Text(message)
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
    }
}

#Preview {
    ToastView(message: "project-3 created — opening Ghostty", systemImage: "checkmark.circle.fill")
        .padding(24)
}
