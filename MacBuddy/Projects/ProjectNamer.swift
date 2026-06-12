import Foundation

enum ProjectNamer {
    static func suggestedName(in folder: URL) -> String {
        let existing = existingNames(in: folder)
        var index = 1
        while existing.contains("project-\(index)") {
            index += 1
        }
        return "project-\(index)"
    }

    static func createProject(named name: String, in folder: URL) throws -> URL {
        let projectURL = folder.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: projectURL.path(percentEncoded: false)) else {
            throw MacBuddyError.projectAlreadyExists(name)
        }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: false)
        return projectURL
    }

    private static func existingNames(in folder: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Set(contents.map { $0.lastPathComponent.lowercased() })
    }
}
