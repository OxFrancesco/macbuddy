import AppKit

/// Writes (and removes) custom icons on app bundles, then restarts the Dock
/// so it picks up the change.
enum DockIconApplier {
    private static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    static func apply(_ bitmap: IconBitmap, toAppAt path: String) -> Bool {
        let image = NSImage(cgImage: bitmap.image, size: NSSize(width: 512, height: 512))
        guard NSWorkspace.shared.setIcon(image, forFile: path, options: []) else { return false }
        refreshCaches(for: path)
        return true
    }

    static func removeCustomIcon(atAppPath path: String) -> Bool {
        guard NSWorkspace.shared.setIcon(nil, forFile: path, options: []) else { return false }
        refreshCaches(for: path)
        return true
    }

    static func relaunchDock() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }

    /// Touch the bundle and force LaunchServices to re-register it, otherwise
    /// the Dock can keep serving the stale icon from the icon-services cache.
    private static func refreshCaches(for path: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: path)
        let process = Process()
        process.executableURL = URL(filePath: lsregisterPath)
        process.arguments = ["-f", path]
        try? process.run()
        process.waitUntilExit()
    }
}
