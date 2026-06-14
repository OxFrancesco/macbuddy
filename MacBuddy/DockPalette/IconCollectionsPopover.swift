import SwiftUI

/// Toolbar button that opens the saved icon collections popover.
struct IconCollectionsButton: View {
    let model: DockPaletteModel
    @State private var isShowingPopover = false

    var body: some View {
        Button {
            isShowingPopover = true
        } label: {
            Image(systemName: "square.stack.3d.up")
        }
        .buttonStyle(IconButtonStyle())
        .help("Icon collections — save generated icon sets and re-apply them anytime")
        .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
            IconCollectionsPopover(model: model, isPresented: $isShowingPopover)
        }
    }
}

/// Save the current generated set under a name; load or delete saved sets.
private struct IconCollectionsPopover: View {
    let model: DockPaletteModel
    @Binding var isPresented: Bool
    @State private var draftName = ""
    @State private var pendingLoad: IconCollection?
    @State private var pendingDelete: IconCollection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Icon collections")

            if !model.aiResults.isEmpty {
                saveRow
            }

            if model.collections.isEmpty {
                Text(model.aiResults.isEmpty
                    ? "Generate AI icons, then save them here as a named set you can re-apply anytime."
                    : "Save your \(model.aiResults.count) generated icons before the next run overwrites them.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.collections) { collection in
                            CollectionRow(
                                collection: collection,
                                onLoad: { requestLoad(collection) },
                                onDelete: { pendingDelete = collection }
                            )
                        }
                    }
                }
                .frame(maxHeight: 280)
                // Attached here, not next to the load dialog — two
                // confirmationDialogs on one view shadow each other.
                .confirmationDialog(
                    "Delete collection?",
                    isPresented: dialogBinding($pendingDelete),
                    presenting: pendingDelete
                ) { collection in
                    Button("Delete “\(collection.name)”", role: .destructive) {
                        model.deleteCollection(collection)
                    }
                } message: { collection in
                    Text("Its \(collection.iconCount) saved icons will be removed. This can't be undone.")
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(Theme.bg)
        .onAppear {
            draftName = model.aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .confirmationDialog(
            "Replace current generated icons?",
            isPresented: dialogBinding($pendingLoad),
            presenting: pendingLoad
        ) { collection in
            Button("Load “\(collection.name)”") { load(collection) }
        } message: { _ in
            Text("Your current generated icons haven't been saved to a collection and will be replaced.")
        }
    }

    private var saveRow: some View {
        HStack(spacing: 8) {
            TextField("Name this set — e.g. claymation", text: $draftName)
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.surfaceRaised, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                .onSubmit(save)

            Button("Save \(model.aiResults.count)", action: save)
                .buttonStyle(GhostButtonStyle())
                .fixedSize()
                .disabled(trimmedName.isEmpty || model.isGeneratingAI)
                .help(model.isGeneratingAI
                    ? "Wait for generation to finish before saving"
                    : "Save the \(model.aiResults.count) generated icons as a collection")
        }
    }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty, !model.isGeneratingAI, !model.aiResults.isEmpty else { return }
        model.saveCollection(named: trimmedName)
        draftName = ""
    }

    private func requestLoad(_ collection: IconCollection) {
        if model.hasUnsavedAIResults {
            pendingLoad = collection
        } else {
            load(collection)
        }
    }

    private func load(_ collection: IconCollection) {
        model.loadCollection(collection)
        isPresented = false
    }

    private func dialogBinding<T>(_ state: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue != nil },
            set: { if !$0 { state.wrappedValue = nil } }
        )
    }
}

private struct CollectionRow: View {
    let collection: IconCollection
    let onLoad: () -> Void
    let onDelete: () -> Void
    @State private var thumbnails: [IconBitmap] = []

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, thumbnail in
                    Image(decorative: thumbnail.image, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                }
            }
            .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(collection.iconCount) icons · \(collection.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 8)

            Button("Load", action: onLoad)
                .buttonStyle(GhostButtonStyle())
                .fixedSize()
                .help("Make this collection the current set, then Apply to Dock")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.alarmRed)
            }
            .buttonStyle(IconButtonStyle())
            .help("Delete this collection")
        }
        .task {
            thumbnails = IconCollectionStore.thumbnails(for: collection, limit: 3, pixelSize: 52)
        }
    }
}
