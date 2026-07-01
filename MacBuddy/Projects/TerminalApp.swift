import AppKit

/// Nonisolated so `isInstalled` (a LaunchServices round-trip) is callable from
/// the concurrent executor as well as the UI.
nonisolated enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal
    case iterm2
    case ghostty
    case alacritty
    case kitty
    case wezterm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm2: "iTerm2"
        case .ghostty: "Ghostty"
        case .alacritty: "Alacritty"
        case .kitty: "kitty"
        case .wezterm: "WezTerm"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm2: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .alacritty: "org.alacritty"
        case .kitty: "net.kovidgoyal.kitty"
        case .wezterm: "com.github.wez.wezterm"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    var menuTitle: String {
        isInstalled ? displayName : "\(displayName) (not installed)"
    }

    static var preferredDefault: TerminalApp {
        TerminalApp.ghostty.isInstalled ? .ghostty : .terminal
    }
}
