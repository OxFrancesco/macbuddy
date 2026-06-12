import SwiftUI

struct NewProjectPromptView: View {
    let folder: URL
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name: String
    @State private var hasAppeared = false
    @FocusState private var isNameFocused: Bool

    init(folder: URL, suggestedName: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.folder = folder
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _name = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("❯")
                    .font(Theme.mono(20, weight: .bold))
                    .foregroundStyle(Theme.amber)
                TextField("project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(18))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($isNameFocused)
                    .onSubmit(submit)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)

            HStack(spacing: 8) {
                Text(destinationDescription)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let validationMessage {
                    Text(validationMessage)
                        .font(Theme.mono(10, weight: .semibold))
                        .foregroundStyle(Theme.alarmRed)
                } else {
                    HStack(spacing: 5) {
                        Keycap("↩")
                        Text("create")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 480)
        .panelGlass()
        .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.94)
        .opacity(hasAppeared ? 1 : 0)
        .onExitCommand(perform: onCancel)
        .defaultFocus($isNameFocused, true)
        .task { animateIn() }
    }

    private func animateIn() {
        isNameFocused = true
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3)) {
            hasAppeared = true
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        if trimmedName.isEmpty {
            nil
        } else if trimmedName.contains("/") || trimmedName.contains(":") {
            "no / or :"
        } else if FileManager.default.fileExists(atPath: folder.appending(path: trimmedName).path(percentEncoded: false)) {
            "already exists"
        } else {
            nil
        }
    }

    private var destinationDescription: String {
        let target = trimmedName.isEmpty ? "…" : trimmedName
        return "mkdir \(folder.path(percentEncoded: false))/\(target)"
    }

    private func submit() {
        guard !trimmedName.isEmpty, validationMessage == nil else { return }
        onSubmit(trimmedName)
    }
}

#Preview {
    NewProjectPromptView(
        folder: URL(filePath: "/tmp"),
        suggestedName: "project-1",
        onSubmit: { _ in },
        onCancel: {}
    )
    .padding(40)
    .background(ThemeBackground())
    .preferredColorScheme(.dark)
}
