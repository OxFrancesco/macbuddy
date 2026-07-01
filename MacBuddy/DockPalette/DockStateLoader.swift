import Foundation

/// Gathers everything the Dock palette needs on reload — Dock order and
/// previews, pristine-icon snapshots, persisted generations, saved
/// collections, and the App Management probe — off the main actor so opening
/// the tab never stalls the UI.
nonisolated enum DockStateLoader {
    struct State: Sendable {
        let apps: [DockApp]
        let generated: [String: IconBitmap]
        let collections: [IconCollection]
        let hasAppManagementAccess: Bool
    }

    @concurrent
    static func load(styledPaths: Set<String>) async -> State {
        let apps = DockReader.dockApps()
        // Snapshot pristine icons before any styling touches them, so re-runs
        // never re-process an already-styled icon.
        OriginalIconStore.ensureCached(appPaths: apps.map(\.path), styledPaths: styledPaths)
        // Restore previously generated AI icons so they can be reviewed,
        // applied, or discarded across launches.
        let generated = await GeneratedIconStore.restore(forAppPaths: apps.map(\.path))
        return State(
            apps: apps,
            generated: generated,
            collections: IconCollectionStore.list(),
            hasAppManagementAccess: hasAppManagementAccess(apps: apps)
        )
    }

    /// Changing another app's icon writes into its bundle, which macOS gates
    /// behind the App Management permission. POSIX writability checks pass
    /// without it, so probe with a real write — this also makes MacBuddy show
    /// up in the App Management list in System Settings.
    static func hasAppManagementAccess(apps: [DockApp]) -> Bool {
        guard let target = apps.first(where: \.isCustomizable) else { return true }
        let probePath = URL(filePath: target.path)
            .appending(path: ".macbuddy-write-probe")
            .path(percentEncoded: false)
        let created = FileManager.default.createFile(atPath: probePath, contents: Data())
        if created {
            try? FileManager.default.removeItem(atPath: probePath)
        }
        return created
    }
}
