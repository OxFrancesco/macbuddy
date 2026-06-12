nonisolated struct DockApp: Identifiable, Sendable {
    let path: String
    let name: String
    let previewSource: IconBitmap?
    let isCustomizable: Bool

    var id: String { path }
}
