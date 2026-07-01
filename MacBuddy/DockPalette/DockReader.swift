import AppKit

/// Reads the pinned apps from the Dock's preferences (com.apple.dock,
/// persistent-apps) in Dock order.
nonisolated enum DockReader {
    static func dockApps() -> [DockApp] {
        guard let dockDefaults = UserDefaults(suiteName: "com.apple.dock"),
              let items = dockDefaults.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return []
        }
        return items.compactMap(dockApp(from:))
    }

    private static func dockApp(from item: [String: Any]) -> DockApp? {
        guard let tileData = item["tile-data"] as? [String: Any],
              let fileData = tileData["file-data"] as? [String: Any],
              let urlString = fileData["_CFURLString"] as? String else {
            return nil
        }
        let urlType = fileData["_CFURLStringType"] as? Int ?? 15
        let url: URL? = if urlType == 15 {
            URL(string: urlString)
        } else {
            URL(filePath: urlString)
        }
        guard let url else { return nil }

        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let name = (tileData["file-label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        return DockApp(
            path: path,
            name: name,
            previewSource: IconRenderer.iconBitmap(forFile: path, pixelSize: 256),
            isCustomizable: FileManager.default.isWritableFile(atPath: path)
        )
    }
}
