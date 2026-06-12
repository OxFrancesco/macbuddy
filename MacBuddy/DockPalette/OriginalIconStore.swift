import AppKit
import CryptoKit

/// Caches each app's pristine icon before MacBuddy styles it. NSWorkspace
/// returns the *custom* icon once one is applied, so styling twice would
/// otherwise re-process an already-styled icon.
enum OriginalIconStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MacBuddy/OriginalIcons", directoryHint: .isDirectory)
    }

    /// Snapshots originals for any app that isn't already cached and isn't
    /// currently carrying a MacBuddy-styled icon.
    static func ensureCached(appPaths: [String], styledPaths: Set<String>) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in appPaths {
            let url = cacheURL(forAppAt: path)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            guard !styledPaths.contains(path) else { continue }
            guard let bitmap = IconRenderer.iconBitmap(forFile: path, pixelSize: 1024) else { continue }
            let rep = NSBitmapImageRep(cgImage: bitmap.image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// The pristine icon at the requested size — cached snapshot if we have
    /// one, the live icon otherwise.
    static func originalBitmap(forAppAt path: String, pixelSize: Int) -> IconBitmap? {
        let url = cacheURL(forAppAt: path)
        if let image = NSImage(contentsOf: url),
           let bitmap = IconRenderer.bitmap(from: image, pixelSize: pixelSize) {
            return bitmap
        }
        return IconRenderer.iconBitmap(forFile: path, pixelSize: pixelSize)
    }

    private static func cacheURL(forAppAt path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).png")
    }
}
