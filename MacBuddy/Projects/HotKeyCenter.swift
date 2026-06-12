import Carbon
import Observation

/// Registers a single system-wide hotkey via Carbon's `RegisterEventHotKey`,
/// which needs no accessibility permission.
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onHotKey: (() -> Void)?
    private(set) var registrationError: String?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4D42_4459 // 'MBDY'

    private init() {}

    func register(_ spec: HotKeySpec?) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registrationError = nil
        guard let spec else { return }

        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            registrationError = "Couldn't register \(spec.displayString) (error \(status)). Another app may already be using it."
        }
    }

    func fire() {
        onHotKey?()
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
    MainActor.assumeIsolated {
        HotKeyCenter.shared.fire()
    }
    return noErr
}
