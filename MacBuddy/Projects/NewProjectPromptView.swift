import SwiftUI

struct NewProjectPromptView: View {
    let folder: URL
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(folder: URL, suggestedName: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.folder = folder
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _name = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Image(systemName: "folder.badge.plus")
                    .font(.title)
                    .foregroundStyle(.tint)
                TextField("Project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($isNameFocused)
                    .onSubmit(submit)
            }
            HStack(spacing: 8) {
                Text(destinationDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .onExitCommand(perform: onCancel)
        .defaultFocus($isNameFocused, true)
        .task { isNameFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        if trimmedName.isEmpty {
            nil
        } else if trimmedName.contains("/") || trimmedName.contains(":") {
            "Name can't contain / or :"
        } else if FileManager.default.fileExists(atPath: folder.appending(path: trimmedName).path(percentEncoded: false)) {
            "Already exists"
        } else {
            nil
        }
    }

    private var destinationDescription: String {
        let target = trimmedName.isEmpty ? "…" : trimmedName
        return "Creates \(folder.appending(path: target).path(percentEncoded: false)) and opens your terminal"
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
}
