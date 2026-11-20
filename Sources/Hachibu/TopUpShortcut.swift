import AppKit
import Carbon.HIToolbox

/// One keyboard shortcut that works in any app: Control-Option-Command-T
/// starts a Top Up, or stops the one that runs. Off until switched on in
/// Settings. Test runs and command-line runs never register it.
///
/// It uses the system's hot key service, which needs no permission: only
/// this one combination reaches Hachibu, never other typing.
enum TopUpShortcut {
    /// The keys, as Settings shows them.
    static let keys = "⌃⌥⌘T"

    nonisolated(unsafe) private static var hotKey: EventHotKeyRef?
    nonisolated(unsafe) private static var handler: EventHandlerRef?

    static var canRegister: Bool { !Store.isOverridden && !Launch.isOneShot }

    /// Registers or releases the shortcut. Returns false when macOS refused
    /// it, which happens when another app holds the same keys.
    @discardableResult
    static func set(enabled: Bool) -> Bool {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard enabled, canRegister else { return true }
        if handler == nil {
            var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in TopUpShortcut.pressed() }
                return noErr
            }, 1, &pressed, nil, &handler)
        }
        // "HCHB": tells this hot key from any other in the process.
        let id = EventHotKeyID(signature: 0x4843_4842, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        return status == noErr
    }

    /// The same as the Top Up button. When a Top Up cannot start (no
    /// charger, already full, a calibration running) the Mac beeps, so the
    /// key press is never silently lost.
    private static func pressed() {
        guard let monitor = BatteryMonitor.current else { return }
        if monitor.mode == .toppingUp || monitor.canTopUp {
            monitor.toggleTopUp()
        } else {
            NSSound.beep()
        }
    }
}
