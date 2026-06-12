import Foundation
import Observation

@Observable
final class AppSettings {
    var projectsFolder: URL? { didSet { persistFolder() } }
    var terminal: TerminalApp { didSet { defaults.set(terminal.rawValue, forKey: Keys.terminal) } }
    var command: String { didSet { defaults.set(command, forKey: Keys.command) } }
    var hotKey: HotKeySpec? { didSet { persistHotKey() } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let folder = "projectsFolderPath"
        static let terminal = "terminalApp"
        static let command = "injectedCommand"
        static let hotKey = "hotKeySpec"
        static let hotKeyCleared = "hotKeyCleared"
    }

    init() {
        let defaults = UserDefaults.standard
        projectsFolder = defaults.string(forKey: Keys.folder).map { URL(filePath: $0, directoryHint: .isDirectory) }
        terminal = defaults.string(forKey: Keys.terminal).flatMap(TerminalApp.init) ?? .preferredDefault
        command = defaults.string(forKey: Keys.command) ?? "claude"
        hotKey = Self.loadHotKey(from: defaults)
    }

    private func persistFolder() {
        if let projectsFolder {
            defaults.set(projectsFolder.path(percentEncoded: false), forKey: Keys.folder)
        } else {
            defaults.removeObject(forKey: Keys.folder)
        }
    }

    private func persistHotKey() {
        if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: Keys.hotKey)
            defaults.set(false, forKey: Keys.hotKeyCleared)
        } else {
            defaults.removeObject(forKey: Keys.hotKey)
            defaults.set(true, forKey: Keys.hotKeyCleared)
        }
    }

    private static func loadHotKey(from defaults: UserDefaults) -> HotKeySpec? {
        if let data = defaults.data(forKey: Keys.hotKey),
           let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data) {
            return spec
        }
        if defaults.bool(forKey: Keys.hotKeyCleared) {
            return nil
        }
        return .default
    }
}
