import Foundation
import Observation

@Observable
final class AppSettings {
    var projectsFolder: URL? { didSet { persistFolder() } }
    var terminal: TerminalApp { didSet { defaults.set(terminal.rawValue, forKey: Keys.terminal) } }
    var command: String { didSet { defaults.set(command, forKey: Keys.command) } }
    var hotKey: HotKeySpec? { didSet { persistHotKey(hotKey, specKey: Keys.hotKey, clearedKey: Keys.hotKeyCleared) } }
    var openProjectHotKey: HotKeySpec? { didSet { persistHotKey(openProjectHotKey, specKey: Keys.openHotKey, clearedKey: Keys.openHotKeyCleared) } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let folder = "projectsFolderPath"
        static let terminal = "terminalApp"
        static let command = "injectedCommand"
        static let hotKey = "hotKeySpec"
        static let hotKeyCleared = "hotKeyCleared"
        static let openHotKey = "openProjectHotKeySpec"
        static let openHotKeyCleared = "openProjectHotKeyCleared"
    }

    init() {
        let defaults = UserDefaults.standard
        projectsFolder = defaults.string(forKey: Keys.folder).map { URL(filePath: $0, directoryHint: .isDirectory) }
        terminal = defaults.string(forKey: Keys.terminal).flatMap(TerminalApp.init) ?? .preferredDefault
        command = defaults.string(forKey: Keys.command) ?? "claude"
        hotKey = Self.loadHotKey(from: defaults, specKey: Keys.hotKey, clearedKey: Keys.hotKeyCleared, fallback: .default)
        openProjectHotKey = Self.loadHotKey(from: defaults, specKey: Keys.openHotKey, clearedKey: Keys.openHotKeyCleared, fallback: .defaultOpenProject)
    }

    private func persistFolder() {
        if let projectsFolder {
            defaults.set(projectsFolder.path(percentEncoded: false), forKey: Keys.folder)
        } else {
            defaults.removeObject(forKey: Keys.folder)
        }
    }

    private func persistHotKey(_ spec: HotKeySpec?, specKey: String, clearedKey: String) {
        if let spec, let data = try? JSONEncoder().encode(spec) {
            defaults.set(data, forKey: specKey)
            defaults.set(false, forKey: clearedKey)
        } else {
            defaults.removeObject(forKey: specKey)
            defaults.set(true, forKey: clearedKey)
        }
    }

    private static func loadHotKey(
        from defaults: UserDefaults,
        specKey: String,
        clearedKey: String,
        fallback: HotKeySpec
    ) -> HotKeySpec? {
        if let data = defaults.data(forKey: specKey),
           let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data) {
            return spec
        }
        if defaults.bool(forKey: clearedKey) {
            return nil
        }
        return fallback
    }
}
