nonisolated enum IconStyle: String, CaseIterable, Identifiable, Sendable {
    case noir
    case ink
    case tint
    case sepia
    case pastel
    case ai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .noir: "Noir"
        case .ink: "B&W"
        case .tint: "Tint"
        case .sepia: "Sepia"
        case .pastel: "Pastel"
        case .ai: "AI"
        }
    }

    /// AI icons are generated on demand via fal.ai, not by the local filter
    /// pipeline.
    var isGenerative: Bool { self == .ai }
}
