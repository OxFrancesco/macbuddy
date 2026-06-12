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
    private(set) var needsAppManagementPermission = false

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
        withAnimation(.easeInOut(duration: 0.25)) {
            needsAppManagementPermission = !hasAppManagementAccess()
        }
    }

    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Changing another app's icon writes into its bundle, which macOS gates
    /// behind the App Management permission. POSIX writability checks pass
    /// without it, so probe with a real write — this also makes MacBuddy show
    /// up in the App Management list in System Settings.
    private func hasAppManagementAccess() -> Bool {
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

    func refreshPreviews() async {
        let tintColor = TintColor(tint)
        for app in apps {
            if Task.isCancelled { return }
            guard let source = app.previewSource else { continue }
            if let styled = await IconStyler.render(source: source, style: style, tint: tintColor, intensity: intensity) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    previews[app.id] = styled
                }
            }
        }
    }

    func applyToDock() async {
        guard hasAppManagementAccess() else {
            withAnimation(.easeInOut(duration: 0.25)) {
                needsAppManagementPermission = true
            }
            presentPermissionAlert()
            return
        }
        needsAppManagementPermission = false
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

        withAnimation(.easeInOut(duration: 0.25)) {
            statusMessage = statusText(applied: appliedPaths.count, failures: failures)
        }
        guard !appliedPaths.isEmpty else {
            if !failures.isEmpty {
                presentPermissionAlert()
            }
            return
        }
        styledPaths = Array(Set(styledPaths).union(appliedPaths))
        defaults.set(styledPaths, forKey: Self.styledPathsKey)
        DockIconApplier.relaunchDock()
        ToastPresenter.show(message: "Dock restyled — \(appliedPaths.count) icons updated", systemImage: "paintpalette.fill")
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

    private func presentPermissionAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Permission needed"
        alert.informativeText = "MacBuddy needs App Management permission to change the icons of other apps. Enable MacBuddy in System Settings → Privacy & Security → App Management, then apply again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openPermissionSettings()
        }
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
