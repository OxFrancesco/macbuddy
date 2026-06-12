import Foundation

nonisolated enum MacBuddyError: LocalizedError {
    case terminalNotInstalled(String)
    case automationDenied(String)
    case scriptFailed(String)
    case projectAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .terminalNotInstalled(let name):
            "\(name) isn't installed. Pick a different terminal in MacBuddy's Projects tab."
        case .automationDenied(let name):
            "MacBuddy isn't allowed to control \(name). Enable it in System Settings → Privacy & Security → Automation."
        case .scriptFailed(let message):
            message
        case .projectAlreadyExists(let name):
            "A folder named “\(name)” already exists."
        }
    }
}
