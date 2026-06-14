import AppKit
import CryptoKit

/// Persists the latest AI-generated icon for each app, so results survive
/// relaunch and can be reviewed, applied, or discarded one by one.
enum GeneratedIconStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MacBuddy/GeneratedIcons", directoryHint: .isDirectory)
    }

    static func save(_ bitmap: IconBitmap, forAppAt path: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: bitmap.image)
        try? rep.representation(using: .png, properties: [:])?.write(to: cacheURL(forAppAt: path))
    }

    static func bitmap(forAppAt path: String) -> IconBitmap? {
        guard let image = NSImage(contentsOf: cacheURL(forAppAt: path)) else { return nil }
        return IconRenderer.bitmap(from: image, pixelSize: 1024)
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
