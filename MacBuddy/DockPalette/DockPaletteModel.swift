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

    // AI style (fal.ai image-to-image)
    var aiPrompt: String { didSet { defaults.set(aiPrompt, forKey: Self.aiPromptKey) } }
    var aiStrength: Double { didSet { defaults.set(aiStrength, forKey: Self.aiStrengthKey) } }
    private(set) var aiResults: [String: IconBitmap] = [:]
    private(set) var generatingPaths: Set<String> = []
    private(set) var falKeyAvailable = false
    private var aiTask: Task<Void, Never>?

    var isGeneratingAI: Bool { !generatingPaths.isEmpty }

    /// Override with `defaults write dev.francescooddo.macbuddy falModelId <id>`
    /// to try a different fal.ai image-to-image endpoint.
    var falModelId: String { defaults.string(forKey: Self.falModelKey) ?? Self.defaultFalModel }

    private var appsVersion = 0
    private let defaults = UserDefaults.standard
    private static let styledPathsKey = "styledAppPaths"
    private static let aiPromptKey = "aiStylePrompt"
    private static let aiStrengthKey = "aiStyleStrength"
    private static let falModelKey = "falModelId"
    static let defaultFalModel = "fal-ai/z-image/turbo/image-to-image"

    struct PreviewKey: Hashable {
        let style: IconStyle
        let tint: Color
        let intensity: Double
        let version: Int
    }

    init() {
        let defaults = UserDefaults.standard
        styledPaths = defaults.stringArray(forKey: Self.styledPathsKey) ?? []
        aiPrompt = defaults.string(forKey: Self.aiPromptKey) ?? ""
        let storedStrength = defaults.double(forKey: Self.aiStrengthKey)
        aiStrength = storedStrength > 0 ? storedStrength : 0.6
        falKeyAvailable = FalKeyStore.keyIsAvailable
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
        // Snapshot pristine icons before any styling touches them, so re-runs
        // never re-process an already-styled icon.
        OriginalIconStore.ensureCached(appPaths: apps.map(\.path), styledPaths: Set(styledPaths))
        falKeyAvailable = FalKeyStore.keyIsAvailable
        withAnimation(.easeInOut(duration: 0.25)) {
            needsAppManagementPermission = !hasAppManagementAccess()
        }
    }

    func refreshFalKeyState() {
        falKeyAvailable = FalKeyStore.keyIsAvailable
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
        if style == .ai {
            // Generation is explicit (it costs API calls); just surface any
            // results we already have.
            var aiPreviews: [String: IconBitmap] = [:]
            for app in apps {
                if let result = aiResults[app.path] {
                    aiPreviews[app.id] = result
                }
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                previews = aiPreviews
            }
            return
        }
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

    // MARK: - AI generation

    func generateAIIcons() {
        guard style == .ai else { return }
        let stylePrompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stylePrompt.isEmpty else {
            statusMessage = "Type a style first — e.g. “watermelon style”."
            return
        }
        guard let apiKey = FalKeyStore.resolveKey() else {
            falKeyAvailable = false
            statusMessage = "Add your fal.ai API key first (key button on the right)."
            return
        }
        aiTask?.cancel()
        let sources = apps.filter(\.isCustomizable).compactMap { app -> AISource? in
            guard let bitmap = OriginalIconStore.originalBitmap(forAppAt: app.path, pixelSize: AIIconStylist.canvasSize) else {
                return nil
            }
            return AISource(path: app.path, name: app.name, bitmap: bitmap)
        }
        guard !sources.isEmpty else { return }
        generatingPaths = Set(sources.map(\.path))
        statusMessage = "Generating \(sources.count) icons…"
        let strength = aiStrength
        let modelId = falModelId
        aiTask = Task { [weak self] in
            await self?.runAIGeneration(
                sources: sources,
                stylePrompt: stylePrompt,
                strength: strength,
                apiKey: apiKey,
                modelId: modelId
            )
        }
    }

    private struct AISource: Sendable {
        let path: String
        let name: String
        let bitmap: IconBitmap
    }

    private func runAIGeneration(
        sources: [AISource],
        stylePrompt: String,
        strength: Double,
        apiKey: String,
        modelId: String
    ) async {
        var failures: [String] = []
        var firstError: String?
        var succeeded = 0

        await withTaskGroup(of: (String, String, Result<IconBitmap, any Error>).self) { group in
            var iterator = sources.makeIterator()
            func addNext() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    do {
                        let bitmap = try await AIIconStylist.restyle(
                            source: item.bitmap,
                            stylePrompt: stylePrompt,
                            strength: strength,
                            apiKey: apiKey,
                            modelId: modelId
                        )
                        return (item.path, item.name, .success(bitmap))
                    } catch {
                        return (item.path, item.name, .failure(error))
                    }
                }
            }
            // Keep a few requests in flight at a time.
            for _ in 0..<3 { addNext() }
            for await (path, name, result) in group {
                generatingPaths.remove(path)
                if Task.isCancelled { continue }
                switch result {
                case .success(let bitmap):
                    succeeded += 1
                    aiResults[path] = bitmap
                    if style == .ai, let app = apps.first(where: { $0.path == path }) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            previews[app.id] = bitmap
                        }
                    }
                case .failure(let error):
                    guard !(error is CancellationError) else { continue }
                    failures.append(name)
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
                addNext()
            }
        }

        // Only clear this run's paths — a newer generation may already be
        // tracking its own.
        generatingPaths.subtract(sources.map(\.path))
        guard !Task.isCancelled else { return }
        var parts = ["AI-styled \(succeeded) of \(sources.count) icons."]
        if !failures.isEmpty {
            parts.append("Failed: \(failures.joined(separator: ", ")).")
            if let firstError {
                parts.append(firstError)
            }
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            statusMessage = parts.joined(separator: " ")
        }
        if succeeded > 0 {
            ToastPresenter.show(message: "Generated \(succeeded) AI icons — review, then Apply to Dock", systemImage: "sparkles")
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
            guard let styled = await styledBitmap(for: app, tint: tintColor),
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

    /// What Apply writes for one app: the cached AI render in AI mode, the
    /// local filter pipeline over the pristine original otherwise.
    private func styledBitmap(for app: DockApp, tint: TintColor) async -> IconBitmap? {
        if style == .ai {
            return aiResults[app.path]
        }
        guard let source = OriginalIconStore.originalBitmap(forAppAt: app.path, pixelSize: 1024) else {
            return nil
        }
        return await IconStyler.render(source: source, style: style, tint: tint, intensity: intensity)
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
