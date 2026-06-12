import AppKit

/// Opens the chosen terminal in a directory and injects the configured command.
/// Terminal.app and iTerm2 are driven via AppleScript; the rest accept CLI
/// arguments through `open -n -b <bundle-id> --args`.
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
        let quotedPath = "'" + directory.path(percentEncoded: false).replacing("'", with: "'\\''") + "'"
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
        var arguments = ["-n", "-b", terminal.bundleIdentifier, "--args"]
        arguments += terminalArguments(terminal, directory: directory, command: command)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            throw MacBuddyError.scriptFailed("Couldn't launch \(terminal.displayName): \(error.localizedDescription)")
        }
    }

    private static func terminalArguments(_ terminal: TerminalApp, directory: URL, command: String) -> [String] {
        let path = directory.path(percentEncoded: false)
        let shellCommand = command.isEmpty ? nil : shellInvocation(for: command)
        return switch terminal {
        case .ghostty:
            ["--working-directory=\(path)"] + (shellCommand.map { ["-e"] + $0 } ?? [])
        case .alacritty:
            ["--working-directory", path] + (shellCommand.map { ["-e"] + $0 } ?? [])
        case .kitty:
            ["--directory", path] + (shellCommand ?? [])
        case .wezterm:
            ["start", "--cwd", path] + (shellCommand.map { ["--"] + $0 } ?? [])
        case .terminal, .iterm2:
            []
        }
    }

    /// Runs the command in an interactive login shell so PATH additions from
    /// the user's profile (bun, npm, homebrew) are available, then drops back
    /// into a shell so the window survives the command exiting.
    private static func shellInvocation(for command: String) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return [shell, "-i", "-l", "-c", "\(command); exec \(shell) -i -l"]
    }
}
