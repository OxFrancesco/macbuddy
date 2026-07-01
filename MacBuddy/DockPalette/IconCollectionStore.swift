import CryptoKit
import Foundation

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
nonisolated enum IconCollectionStore {
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

    /// Runs off the main actor — encoding a full set of 1024px PNGs is too
    /// heavy for the main thread.
    @concurrent
    static func save(name: String, prompt: String, icons: [String: IconBitmap]) async -> IconCollection? {
        let id = UUID()
        let createdAt = Date.now
        let sortedIcons = icons.sorted { $0.key < $1.key }
        let appPaths = sortedIcons.map(\.key)
        let folder = folderURL(for: id)
        let temporaryFolder = temporaryFolderURL(for: id)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: false)
            for (path, bitmap) in sortedIcons {
                guard let png = IconPNG.data(from: bitmap.image) else {
                    throw SaveError.pngEncodingFailed(path)
                }
                try png.write(to: iconURL(in: temporaryFolder, appPath: path), options: .atomic)
            }
            let manifest = Manifest(name: name, prompt: prompt, createdAt: createdAt, appPaths: appPaths)
            try JSONEncoder()
                .encode(manifest)
                .write(to: temporaryFolder.appending(path: "manifest.json"), options: .atomic)
            try FileManager.default.moveItem(at: temporaryFolder, to: folder)
        } catch {
            try? FileManager.default.removeItem(at: temporaryFolder)
            return nil
        }
        return IconCollection(id: id, name: name, prompt: prompt, createdAt: createdAt, appPaths: appPaths)
    }

    /// Full-resolution icons keyed by app path, decoded off the main actor.
    @concurrent
    static func icons(for collection: IconCollection) async -> [String: IconBitmap] {
        let folder = folderURL(for: collection.id)
        var result: [String: IconBitmap] = [:]
        for path in collection.appPaths {
            guard let image = IconPNG.image(contentsOf: iconURL(in: folder, appPath: path)) else { continue }
            result[path] = IconBitmap(image: image)
        }
        return result
    }

    /// Small previews for the collections list, downsampled at decode time.
    static func thumbnails(for collection: IconCollection, limit: Int, pixelSize: Int) -> [IconBitmap] {
        let folder = folderURL(for: collection.id)
        return collection.appPaths.prefix(limit).compactMap { path in
            guard let image = IconPNG.image(
                contentsOf: iconURL(in: folder, appPath: path),
                maxPixelSize: pixelSize
            ) else { return nil }
            return IconBitmap(image: image)
        }
    }

    static func delete(_ collection: IconCollection) {
        try? FileManager.default.removeItem(at: folderURL(for: collection.id))
    }

    private static func folderURL(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private static func temporaryFolderURL(for id: UUID) -> URL {
        root.appending(path: ".\(id.uuidString).tmp", directoryHint: .isDirectory)
    }

    private static func iconURL(in folder: URL, appPath: String) -> URL {
        let digest = SHA256.hash(data: Data(appPath.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: "\(name).png")
    }

    private enum SaveError: Error {
        case pngEncodingFailed(String)
    }
}
