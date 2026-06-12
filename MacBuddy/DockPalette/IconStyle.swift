nonisolated enum IconStyle: String, CaseIterable, Identifiable, Sendable {
    case noir
    case ink
    case tint
    case sepia
    case pastel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .noir: "Noir"
        case .ink: "B&W"
        case .tint: "Tint"
        case .sepia: "Sepia"
        case .pastel: "Pastel"
        }
    }
}
