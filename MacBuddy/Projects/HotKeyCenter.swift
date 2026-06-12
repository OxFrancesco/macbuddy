import Carbon
import Observation

/// The global actions a hotkey can trigger. Raw values double as the Carbon
/// `EventHotKeyID.id`, so each case must stay unique and stable.
nonisolated enum HotKeyAction: UInt32, CaseIterable {
    case newProject = 1
    case openProject = 2
}

/// Registers system-wide hotkeys via Carbon's `RegisterEventHotKey`,
/// which needs no accessibility permission.
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onHotKey: ((HotKeyAction) -> Void)?
    private(set) var registrationErrors: [HotKeyAction: String] = [:]

    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4D42_4459 // 'MBDY'

    private init() {}

    func register(_ spec: HotKeySpec?, for action: HotKeyAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        registrationErrors[action] = nil
        guard let spec else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[action] = ref
        } else {
            registrationErrors[action] = "Couldn't register \(spec.displayString) (error \(status)). Another app may already be using it."
        }
    }

    func registrationError(for action: HotKeyAction) -> String? {
        registrationErrors[action]
    }

    func fire(_ action: HotKeyAction) {
        onHotKey?(action)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), handleHotKeyEvent, 1, &eventType, nil, &eventHandlerRef)
    }
}

/// Carbon dispatches hotkey events on the main run loop, so hopping back onto
/// the main actor here is safe.
private nonisolated func handleHotKeyEvent(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard let action = HotKeyAction(rawValue: hotKeyID.id) else { return noErr }
    MainActor.assumeIsolated {
        HotKeyCenter.shared.fire(action)
    }
    return noErr
}
