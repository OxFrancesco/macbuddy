import AppKit
import Observation
import SwiftUI

@Observable
final class DockPaletteModel {
    private(set) var apps: [DockApp] = []
    private(set) var previews: [String: IconBitmap] = [:]
    private(set) var isBusy = false
    private(set) var statusMessage: String?
    private(set) var styledPaths: [String]

    var style: IconStyle = .noir
    var tint: Color = .blue
    var intensity = 1.0

    private var appsVersion = 0
    private let defaults = UserDefaults.standard
    private static let styledPathsKey = "styledAppPaths"

    struct PreviewKey: Hashable {
        let style: IconStyle
        let tint: Color
        let intensity: Double
        let version: Int
    }

    init() {
        styledPaths = UserDefaults.standard.stringArray(forKey: Self.styledPathsKey) ?? []
    }

    var previewKey: PreviewKey {
        PreviewKey(style: style, tint: tint, intensity: intensity, version: appsVersion)
    }

    func loadIfNeeded() {
        if apps.isEmpty {
            reload()
        }
    }

    func reload() {
        apps = DockReader.dockApps()
        previews = [:]
        appsVersion += 1
        statusMessage = nil
    }

    func refreshPreviews() async {
        let tintColor = TintColor(tint)
        for app in apps {
            if Task.isCancelled { return }
            guard let source = app.previewSource else { continue }
            if let styled = await IconStyler.render(source: source, style: style, tint: tintColor, intensity: intensity) {
                previews[app.id] = styled
            }
        }
    }

    func applyToDock() async {
        isBusy = true
        statusMessage = "Styling icons…"
        defer { isBusy = false }

        let tintColor = TintColor(tint)
        var appliedPaths: [String] = []
        var failures: [String] = []

        for app in apps where app.isCustomizable {
            guard let source = IconRenderer.iconBitmap(forFile: app.path, pixelSize: 1024),
                  let styled = await IconStyler.render(source: source, style: style, tint: tintColor, intensity: intensity),
                  DockIconApplier.apply(styled, toAppAt: app.path) else {
                failures.append(app.name)
                continue
            }
            appliedPaths.append(app.path)
        }

        styledPaths = Array(Set(styledPaths).union(appliedPaths))
        defaults.set(styledPaths, forKey: Self.styledPathsKey)
        DockIconApplier.relaunchDock()
        statusMessage = statusText(applied: appliedPaths.count, failures: failures)
    }

    func restoreOriginalIcons() {
        var remaining: [String] = []
        for path in styledPaths {
            let removed = DockIconApplier.removeCustomIcon(atAppPath: path)
            if !removed, FileManager.default.fileExists(atPath: path) {
                remaining.append(path)
            }
        }
        styledPaths = remaining
        defaults.set(styledPaths, forKey: Self.styledPathsKey)
        DockIconApplier.relaunchDock()
        statusMessage = remaining.isEmpty ? "Restored original icons." : "Some icons couldn't be restored."
    }

    private func statusText(applied: Int, failures: [String]) -> String {
        let skipped = apps.count(where: { !$0.isCustomizable })
        var parts = ["Styled \(applied) of \(apps.count) Dock icons."]
        if skipped > 0 {
            parts.append("\(skipped) system \(skipped == 1 ? "app" : "apps") skipped.")
        }
        if !failures.isEmpty {
            parts.append("Failed: \(failures.joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}
