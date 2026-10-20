import AppKit
import Carbon

/// System-wide hotkeys. Carbon's hotkey API works without Accessibility permission.
@MainActor
final class Hotkeys {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    /// ⌃⌥⌘ plus a key, e.g. `kVK_ANSI_E`.
    nonisolated static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    func register(_ keyCode: Int, modifiers: UInt32 = Hotkeys.modifiers, _ handler: @escaping () -> Void) {
        install()
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        // "TTHK": this app's hotkey signature.
        let hotKeyID = EventHotKeyID(signature: OSType(0x5454_484B), id: id)
        RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard let userData else { return noErr }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { hotkeys.handlers[id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}
