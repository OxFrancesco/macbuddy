import CoreGraphics

/// Sendable wrapper for CGImage. CGImage is immutable and thread-safe, so
/// shipping it between the main actor and the rendering executor is sound.
nonisolated struct IconBitmap: @unchecked Sendable {
    let image: CGImage
}
