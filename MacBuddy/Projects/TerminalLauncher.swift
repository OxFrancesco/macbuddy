import AppKit

/// Opens the chosen terminal in a directory and injects the configured command.
/// Terminal.app and iTerm2 are driven via AppleScript. The CLI terminals get a
/// single-token executable launch script via `open -n -b <bundle-id> --args`:
/// Ghostty's macOS launcher space-joins multi-token `-e` commands without
/// preserving quoting, so anything with embedded spaces or semicolons gets
/// mangled — a zero-argument script sidesteps that entirely.
enum TerminalLauncher {
    static func launch(_ terminal: TerminalApp, at directory: URL, command rawCommand: String) throws {
        guard terminal.isInstalled else {
            throw MacBuddyError.terminalNotInstalled(terminal.displayName)
        }
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        switch terminal {
        case .terminal:
            try runAppleScript(terminalAppScript(directory: directory, command: command), appName: "Terminal")
        case .iterm2:
            try runAppleScript(itermScript(directory: directory, command: command), appName: "iTerm2")
        case .ghostty, .alacritty, .kitty, .wezterm:
            try openViaLaunchServices(terminal, directory: directory, command: command)
        }
    }

    // MARK: - AppleScript terminals

    private static func shellLine(directory: URL, command: String) -> String {
        let quotedPath = shellQuoted(directory.path(percentEncoded: false))
        return command.isEmpty ? "cd \(quotedPath)" : "cd \(quotedPath) && \(command)"
    }

    private static func terminalAppScript(directory: URL, command: String) -> String {
        let line = appleScriptQuoted(shellLine(directory: directory, command: command))
        return """
        tell application "Terminal"
            activate
            do script \(line)
        end tell
        """
    }

    private static func itermScript(directory: URL, command: String) -> String {
        let line = appleScriptQuoted(shellLine(directory: directory, command: command))
        return """
        tell application "iTerm"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                write text \(line)
            end tell
        end tell
        """
    }

    private static func appleScriptQuoted(_ string: String) -> String {
        "\"" + string.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
    }

    private static func runAppleScript(_ source: String, appName: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw MacBuddyError.scriptFailed("Couldn't build the launch script.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? 0
            if code == -1743 {
                throw MacBuddyError.automationDenied(appName)
            }
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error \(code)."
            throw MacBuddyError.scriptFailed(message)
        }
    }

    // MARK: - CLI terminals

    private static func openViaLaunchServices(_ terminal: TerminalApp, directory: URL, command: String) throws {
        let scriptPath = try writeLaunchScript(directory: directory, command: command)
        var arguments = ["-n", "-b", terminal.bundleIdentifier, "--args"]
        arguments += terminalArguments(terminal, directory: directory, scriptPath: scriptPath)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            throw MacBuddyError.scriptFailed("Couldn't launch \(terminal.displayName): \(error.localizedDescription)")
        }
    }

    private static func terminalArguments(_ terminal: TerminalApp, directory: URL, scriptPath: String) -> [String] {
        let path = directory.path(percentEncoded: false)
        return switch terminal {
        case .ghostty:
            ["--working-directory=\(path)", "-e", scriptPath]
        case .alacritty:
            ["--working-directory", path, "-e", scriptPath]
        case .kitty:
            ["--directory", path, scriptPath]
        case .wezterm:
            ["start", "--cwd", path, "--", scriptPath]
        case .terminal, .iterm2:
            []
        }
    }

    /// Writes a self-contained launch script: cd into the project, run the
    /// command in an interactive login shell (so PATH and aliases from the
    /// user's profile apply), then drop into a shell so the window stays open.
    private static func writeLaunchScript(directory: URL, command: String) throws -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let quotedDirectory = shellQuoted(directory.path(percentEncoded: false))
        var lines = ["#!/bin/zsh", "cd \(quotedDirectory) || exit 1"]
        if command.isEmpty {
            lines.append("exec \(shell) -i -l")
        } else {
            let payload = shellQuoted("\(command); exec \(shell) -i -l")
            lines.append("exec \(shell) -i -l -c \(payload)")
        }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "MacBuddy-launch-\(UUID().uuidString.prefix(8)).zsh")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        let path = url.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacing("'", with: "'\\''") + "'"
    }
}
