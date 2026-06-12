import SwiftUI

struct DockPermissionBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacBuddy needs permission to change app icons")
                    .font(.callout)
                    .fontWeight(.semibold)
                Text("Enable MacBuddy under System Settings → Privacy & Security → App Management, then come back and apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings", action: onOpenSettings)
        }
        .padding(16)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

#Preview {
    DockPermissionBanner(onOpenSettings: {})
        .frame(width: 640)
        .padding(.top, 16)
}
