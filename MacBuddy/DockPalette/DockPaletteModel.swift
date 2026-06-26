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
    private var aiGenerationTasks: [Int: Task<Void, Never>] = [:]
    private var aiGenerationOwners: [String: Int] = [:]
    private var nextAIGenerationID = 0

    // Saved icon collections (named snapshots of generated sets).
    private(set) var collections: [IconCollection] = []
    /// True while the working set has generations not captured in any
    /// collection — loading a collection would lose them.
    private(set) var hasUnsavedAIResults: Bool {
        didSet { defaults.set(hasUnsavedAIResults, forKey: Self.unsavedAIResultsKey) }
    }

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
    private static let unsavedAIResultsKey = "hasUnsavedAIResults"
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
        hasUnsavedAIResults = defaults.bool(forKey: Self.unsavedAIResultsKey)
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
        invalidateAIGenerations()
        apps = DockReader.dockApps()
        previews = [:]
        appsVersion += 1
        statusMessage = nil
        // Snapshot pristine icons before any styling touches them, so re-runs
        // never re-process an already-styled icon.
        OriginalIconStore.ensureCached(appPaths: apps.map(\.path), styledPaths: Set(styledPaths))
        // Restore previously generated AI icons so they can be reviewed,
        // applied, or discarded across launches.
        var restored: [String: IconBitmap] = [:]
        for app in apps {
            if let bitmap = GeneratedIconStore.bitmap(forAppAt: app.path) {
                restored[app.path] = bitmap
            }
        }
        aiResults = restored
        collections = IconCollectionStore.list()
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
        startAIGeneration(limitedTo: nil)
    }

    /// Regenerates a single icon without touching the others.
    func regenerateAIIcon(forAppPath path: String) {
        guard !generatingPaths.contains(path) else { return }
        startAIGeneration(limitedTo: [path])
    }

    private func startAIGeneration(limitedTo paths: Set<String>?) {
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
        let candidates = apps.filter { app in
            app.isCustomizable && (paths?.contains(app.path) ?? true)
        }
        let sources = candidates.compactMap { app -> AISource? in
            guard let bitmap = OriginalIconStore.originalBitmap(forAppAt: app.path, pixelSize: AIIconStylist.canvasSize) else {
                return nil
            }
            return AISource(path: app.path, name: app.name, bitmap: bitmap)
        }
        guard !sources.isEmpty else { return }
        let strength = aiStrength
        let modelId = falModelId
        if paths == nil {
            // A full run replaces any previous one.
            invalidateAIGenerations()
            let generationID = beginAIGeneration(owning: Set(sources.map(\.path)))
            statusMessage = "Generating \(sources.count) icons…"
            aiGenerationTasks[generationID] = Task { [weak self] in
                await self?.runAIGeneration(
                    sources: sources,
                    stylePrompt: stylePrompt,
                    strength: strength,
                    apiKey: apiKey,
                    modelId: modelId,
                    generationID: generationID
                )
            }
        } else {
            // A single-icon redo runs alongside whatever else is in flight.
            let generationID = beginAIGeneration(owning: Set(sources.map(\.path)))
            statusMessage = "Regenerating \(sources[0].name)…"
            aiGenerationTasks[generationID] = Task { [weak self] in
                await self?.runAIGeneration(
                    sources: sources,
                    stylePrompt: stylePrompt,
                    strength: strength,
                    apiKey: apiKey,
                    modelId: modelId,
                    generationID: generationID
                )
            }
        }
    }

    private struct AISource: Sendable {
        let path: String
        let name: String
        let bitmap: IconBitmap
    }

    private enum AIGenerationCommit {
        case success
        case failure(message: String)
        case cancelled
    }

    private func beginAIGeneration(owning paths: Set<String>) -> Int {
        nextAIGenerationID += 1
        let generationID = nextAIGenerationID
        let previousIDs = Set(paths.compactMap { aiGenerationOwners[$0] })

        generatingPaths.formUnion(paths)
        for path in paths {
            aiGenerationOwners[path] = generationID
        }
        for previousID in previousIDs {
            cancelAIGenerationIfUnowned(previousID)
        }
        return generationID
    }

    private func invalidateAIGenerations() {
        for task in aiGenerationTasks.values {
            task.cancel()
        }
        aiGenerationTasks = [:]
        aiGenerationOwners = [:]
        generatingPaths = []
    }

    private func invalidateAIGeneration(forAppPath path: String) {
        guard let generationID = aiGenerationOwners.removeValue(forKey: path) else {
            generatingPaths.remove(path)
            return
        }
        generatingPaths.remove(path)
        cancelAIGenerationIfUnowned(generationID)
    }

    private func cancelAIGenerationIfUnowned(_ generationID: Int) {
        guard !aiGenerationOwners.values.contains(generationID) else { return }
        aiGenerationTasks[generationID]?.cancel()
        aiGenerationTasks[generationID] = nil
    }

    private func commitAIGenerationResult(
        _ result: Result<IconBitmap, any Error>,
        forPath path: String,
        generationID: Int
    ) -> AIGenerationCommit? {
        guard aiGenerationOwners[path] == generationID else { return nil }
        aiGenerationOwners.removeValue(forKey: path)
        generatingPaths.remove(path)

        switch result {
        case .success(let bitmap):
            aiResults[path] = bitmap
            hasUnsavedAIResults = true
            GeneratedIconStore.save(bitmap, forAppAt: path)
            if style == .ai, let app = apps.first(where: { $0.path == path }) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    previews[app.id] = bitmap
                }
            }
            return .success
        case .failure(let error):
            guard !(error is CancellationError) else { return .cancelled }
            return .failure(message: error.localizedDescription)
        }
    }

    private func finishAIGeneration(_ generationID: Int, paths: [String]) -> Bool {
        let hadTask = aiGenerationTasks[generationID] != nil
        for path in paths where aiGenerationOwners[path] == generationID {
            aiGenerationOwners.removeValue(forKey: path)
            generatingPaths.remove(path)
        }
        aiGenerationTasks[generationID] = nil
        return hadTask
    }

    private func runAIGeneration(
        sources: [AISource],
        stylePrompt: String,
        strength: Double,
        apiKey: String,
        modelId: String,
        generationID: Int
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
                            appName: item.name,
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
                // A cancelled run no longer owns these paths — a newer run may
                // be tracking them.
                if Task.isCancelled { continue }
                guard let commit = commitAIGenerationResult(
                    result,
                    forPath: path,
                    generationID: generationID
                ) else {
                    continue
                }
                switch commit {
                case .success:
                    succeeded += 1
                case .failure(let message):
                    failures.append(name)
                    if firstError == nil {
                        firstError = message
                    }
                case .cancelled:
                    break
                }
                addNext()
            }
        }

        // Only clear this run's paths — and only if this run wasn't replaced.
        guard finishAIGeneration(generationID, paths: sources.map(\.path)),
              !Task.isCancelled else { return }
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
            // In AI mode only apply icons the user generated and kept —
            // discarded or never-generated apps keep their current icon.
            if style == .ai, aiResults[app.path] == nil { continue }
            guard let styled = await styledBitmap(for: app, tint: tintColor),
                  DockIconApplier.apply(styled, toAppAt: app.path) else {
                failures.append(app.name)
                continue
            }
            appliedPaths.append(app.path)
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            statusMessage = statusText(
                applied: appliedPaths.count,
                failures: failures,
                runningApps: runningAppNames(in: appliedPaths)
            )
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

    /// Drops one generated icon — the grid falls back to the app's current
    /// icon and Apply will leave that app untouched.
    func discardAIResult(forAppPath path: String) {
        invalidateAIGeneration(forAppPath: path)
        aiResults.removeValue(forKey: path)
        GeneratedIconStore.delete(forAppAt: path)
        if aiResults.isEmpty {
            hasUnsavedAIResults = false
        }
        guard style == .ai, let app = apps.first(where: { $0.path == path }) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            _ = previews.removeValue(forKey: app.id)
        }
    }

    func discardAllAIResults() {
        invalidateAIGenerations()
        aiResults = [:]
        GeneratedIconStore.deleteAll()
        hasUnsavedAIResults = false
        if style == .ai {
            withAnimation(.easeInOut(duration: 0.18)) {
                previews = [:]
            }
        }
        statusMessage = "Discarded all generated icons."
    }

    // MARK: - Icon collections

    /// Snapshots the current generated set under a name, so the next
    /// generation run doesn't overwrite it.
    func saveCollection(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !aiResults.isEmpty else { return }
        let prompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let collection = IconCollectionStore.save(name: name, prompt: prompt, icons: aiResults) else {
            statusMessage = "Couldn't save the collection."
            return
        }
        collections.insert(collection, at: 0)
        hasUnsavedAIResults = false
        statusMessage = "Saved “\(collection.name)” — \(collection.iconCount) icons."
        ToastPresenter.show(message: "Collection “\(collection.name)” saved", systemImage: "square.stack.3d.up.fill")
    }

    /// Makes a saved collection the working set: its icons become the live
    /// previews and what Apply writes, and its prompt comes back so
    /// per-icon regeneration matches the set's style.
    func loadCollection(_ collection: IconCollection) {
        let icons = IconCollectionStore.icons(for: collection)
        guard !icons.isEmpty else {
            statusMessage = "“\(collection.name)” has no readable icons."
            return
        }
        invalidateAIGenerations()
        GeneratedIconStore.deleteAll()
        for (path, bitmap) in icons {
            GeneratedIconStore.save(bitmap, forAppAt: path)
        }
        aiResults = icons
        hasUnsavedAIResults = false
        if !collection.prompt.isEmpty {
            aiPrompt = collection.prompt
        }
        style = .ai
        var aiPreviews: [String: IconBitmap] = [:]
        for app in apps {
            if let result = icons[app.path] {
                aiPreviews[app.id] = result
            }
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            previews = aiPreviews
        }
        let missing = icons.count - aiPreviews.count
        var parts = ["Loaded “\(collection.name)” — \(aiPreviews.count) icons ready."]
        if missing > 0 {
            parts.append("\(missing) saved \(missing == 1 ? "app is" : "apps are") no longer in your Dock.")
        }
        statusMessage = parts.joined(separator: " ")
        ToastPresenter.show(message: "Loaded “\(collection.name)” — review, then Apply to Dock", systemImage: "square.stack.3d.up.fill")
    }

    func deleteCollection(_ collection: IconCollection) {
        IconCollectionStore.delete(collection)
        collections.removeAll { $0.id == collection.id }
        statusMessage = "Deleted “\(collection.name)”."
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

    private func statusText(applied: Int, failures: [String], runningApps: [String]) -> String {
        let skipped = apps.count(where: { !$0.isCustomizable })
        var parts = ["Styled \(applied) of \(apps.count) Dock icons."]
        if skipped > 0 {
            parts.append("\(skipped) system \(skipped == 1 ? "app" : "apps") skipped.")
        }
        if !failures.isEmpty {
            parts.append("Failed: \(failures.joined(separator: ", ")).")
        }
        if !runningApps.isEmpty {
            parts.append("Quit & reopen \(runningApps.joined(separator: ", ")) to see their new icons in the Dock.")
        }
        return parts.joined(separator: " ")
    }

    /// Running apps keep their old Dock tile until relaunched — surface which
    /// of the just-styled apps that affects.
    private func runningAppNames(in appliedPaths: [String]) -> [String] {
        let runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap {
            $0.bundleURL?.path(percentEncoded: false)
        }.map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        return apps.filter { app in
            let normalized = app.path.hasSuffix("/") ? app.path : app.path + "/"
            return appliedPaths.contains(app.path) && runningPaths.contains(normalized)
        }.map(\.name)
    }
}
