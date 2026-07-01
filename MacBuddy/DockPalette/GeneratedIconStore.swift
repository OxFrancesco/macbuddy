import CryptoKit
import Foundation

/// Persists the latest AI-generated icon for each app, so results survive
/// relaunch and can be reviewed, applied, or discarded one by one.
nonisolated enum GeneratedIconStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MacBuddy/GeneratedIcons", directoryHint: .isDirectory)
    }

    static func save(_ bitmap: IconBitmap, forAppAt path: String) {
        guard let data = IconPNG.data(from: bitmap.image) else { return }
        save(pngData: data, forAppAt: path)
    }

    /// Pre-encoded variant so generation can do the (expensive) PNG encode
    /// off the main actor and commit with a plain file write.
    static func save(pngData: Data, forAppAt path: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? pngData.write(to: cacheURL(forAppAt: path), options: .atomic)
    }

    static func bitmap(forAppAt path: String) -> IconBitmap? {
        guard let image = IconPNG.image(contentsOf: cacheURL(forAppAt: path)) else { return nil }
        return IconBitmap(image: image)
    }

    /// Restores every persisted generation for the given apps in one pass,
    /// off the main actor — decoding a Dock's worth of 1024px PNGs is too
    /// heavy for reload on the main thread.
    @concurrent
    static func restore(forAppPaths paths: [String]) async -> [String: IconBitmap] {
        var restored: [String: IconBitmap] = [:]
        for path in paths {
            if let bitmap = bitmap(forAppAt: path) {
                restored[path] = bitmap
            }
        }
        return restored
    }

    /// Swaps the persisted working set for a loaded collection in one
    /// background pass — encoding a full set of 1024px PNGs would otherwise
    /// beachball the main thread.
    @concurrent
    static func replaceAll(with icons: [String: IconBitmap]) async {
        deleteAll()
        for (path, bitmap) in icons {
            save(bitmap, forAppAt: path)
        }
    }

    static func delete(forAppAt path: String) {
        try? FileManager.default.removeItem(at: cacheURL(forAppAt: path))
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func cacheURL(forAppAt path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).png")
    }
}
