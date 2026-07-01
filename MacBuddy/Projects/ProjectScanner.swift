import Foundation

nonisolated struct ProjectEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let modifiedAt: Date?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Lists the project folders inside the configured projects folder, most
/// recently modified first so the search panel starts on recent work.
/// Nonisolated so the directory enumeration can run off the main actor.
nonisolated enum ProjectScanner {
    static func entries(in folder: URL) -> [ProjectEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .compactMap { url -> ProjectEntry? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true else { return nil }
                return ProjectEntry(url: url, modifiedAt: values?.contentModificationDate)
            }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }
}
