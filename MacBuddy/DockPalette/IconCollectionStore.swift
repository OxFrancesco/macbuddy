import AppKit
import CryptoKit

/// A named snapshot of AI-generated icons. Generations are expensive
/// (minutes per icon), so saved sets are kept immutable — loading one copies
/// it into the working set instead of pointing at it.
nonisolated struct IconCollection: Identifiable, Sendable {
    let id: UUID
    let name: String
    let prompt: String
    let createdAt: Date
    let appPaths: [String]

    var iconCount: Int { appPaths.count }
}

/// Persists icon collections, one folder per collection: a manifest plus the
/// icon PNGs, keyed by SHA256 of the app path like the working-set stores.
enum IconCollectionStore {
    private struct Manifest: Codable {
        var name: String
        var prompt: String
        var createdAt: Date
        var appPaths: [String]
    }

    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MacBuddy/IconCollections", directoryHint: .isDirectory)
    }

    static func list() -> [IconCollection] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return folders.compactMap { folder -> IconCollection? in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                return nil
            }
            return IconCollection(
                id: id,
                name: manifest.name,
                prompt: manifest.prompt,
                createdAt: manifest.createdAt,
                appPaths: manifest.appPaths
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func save(name: String, prompt: String, icons: [String: IconBitmap]) -> IconCollection? {
        let id = UUID()
        let createdAt = Date.now
        let folder = folderURL(for: id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (path, bitmap) in icons {
                let rep = NSBitmapImageRep(cgImage: bitmap.image)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: iconURL(in: folder, appPath: path))
            }
            let manifest = Manifest(name: name, prompt: prompt, createdAt: createdAt, appPaths: icons.keys.sorted())
            try JSONEncoder().encode(manifest).write(to: folder.appending(path: "manifest.json"))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return IconCollection(id: id, name: name, prompt: prompt, createdAt: createdAt, appPaths: icons.keys.sorted())
    }

    /// Full-resolution icons keyed by app path.
    static func icons(for collection: IconCollection) -> [String: IconBitmap] {
        let folder = folderURL(for: collection.id)
        var result: [String: IconBitmap] = [:]
        for path in collection.appPaths {
            guard let image = NSImage(contentsOf: iconURL(in: folder, appPath: path)),
                  let bitmap = IconRenderer.bitmap(from: image, pixelSize: 1024) else { continue }
            result[path] = bitmap
        }
        return result
    }

    /// Small previews for the collections list.
    static func thumbnails(for collection: IconCollection, limit: Int, pixelSize: Int) -> [IconBitmap] {
        let folder = folderURL(for: collection.id)
        return collection.appPaths.prefix(limit).compactMap { path in
            guard let image = NSImage(contentsOf: iconURL(in: folder, appPath: path)) else { return nil }
            return IconRenderer.bitmap(from: image, pixelSize: pixelSize)
        }
    }

    static func delete(_ collection: IconCollection) {
        try? FileManager.default.removeItem(at: folderURL(for: collection.id))
    }

    private static func folderURL(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private static func iconURL(in folder: URL, appPath: String) -> URL {
        let digest = SHA256.hash(data: Data(appPath.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: "\(name).png")
    }
}
