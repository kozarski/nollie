#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// Control-Option-Command-Period stops a bot using the Mac from any app. Registered only while a
/// task runs, through the system's hot key service, which needs no permission and sees no other
/// keys.
@MainActor
final class ComputerStopShortcut {
    static let shared = ComputerStopShortcut()
    static let label = "\u{2303}\u{2325}\u{2318}."

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    var isRegistered: Bool { hotKey != nil }

    func register(_ action: @escaping @MainActor () -> Void) {
        self.action = action
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { ComputerStopShortcut.shared.action?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else { return }
        let id = EventHotKeyID(signature: OSType(0x4E4F4C4C), id: 1) // "NOLL"
        RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
    }
}
#endif
