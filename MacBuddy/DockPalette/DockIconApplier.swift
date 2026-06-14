import AppKit

/// Writes (and removes) custom icons on app bundles, then restarts the Dock
/// so it picks up the change.
enum DockIconApplier {
    static func apply(_ bitmap: IconBitmap, toAppAt path: String) -> Bool {
        let image = NSImage(cgImage: bitmap.image, size: NSSize(width: 512, height: 512))
        guard NSWorkspace.shared.setIcon(image, forFile: path, options: []) else { return false }
        // setIcon can set the custom-icon Finder flag yet fail to write the
        // Icon\r resource — which renders as a *blank* icon. Verify, and roll
        // back to the bundle's own icon rather than leave that state.
        let iconFile = URL(filePath: path).appending(path: "Icon\r").path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: iconFile) else {
            _ = NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
            return false
        }
        touch(path)
        return true
    }

    static func removeCustomIcon(atAppPath path: String) -> Bool {
        guard NSWorkspace.shared.setIcon(nil, forFile: path, options: []) else { return false }
        touch(path)
        return true
    }

    static func relaunchDock() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }

    /// Nudges the icon-services cache to notice the bundle changed.
    private static func touch(_ path: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: path)
    }
}
