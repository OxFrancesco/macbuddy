import SwiftUI

struct DockPermissionBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacBuddy needs permission to change app icons")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                Text("Enable MacBuddy under System Settings → Privacy & Security → App Management, then come back and apply.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(GhostButtonStyle())
        }
        .padding(16)
        .background(Theme.amber.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.amber.opacity(0.25)))
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}

#Preview {
    DockPermissionBanner(onOpenSettings: {})
        .frame(width: 640)
        .padding(.top, 16)
}
