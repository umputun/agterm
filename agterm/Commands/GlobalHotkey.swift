import agtermCore
import AppKit
import Carbon.HIToolbox

/// The system-wide chord that summons the quick terminal, registered with the OS through Carbon's
/// `RegisterEventHotKey` so it fires while another application is frontmost — which the app's own
/// `NSEvent.addLocalMonitorForEvents` monitor, gated on agterm's key window, structurally cannot do.
///
/// Carbon rather than `NSEvent.addGlobalMonitorForEvents`: the global monitor needs an Accessibility grant,
/// fails silently when it is missing or revoked, and observes rather than consumes, so the chord would also
/// reach whatever application is in front. `RegisterEventHotKey` needs no TCC grant and takes the key.
///
/// The chord is registered by physical key POSITION, `keyCode(forChordKey:)` resolving it, so it keeps
/// firing when the user switches to a non-Latin layout — the same choice `CustomCommandRunner` makes for
/// non-ASCII layouts.
@MainActor
final class GlobalHotkey {
    private let settings: SettingsModel

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var keymapObserver: NSObjectProtocol?

    /// The `RegisterEventHotKey` id this app uses. Only one hotkey is ever registered, so the signature and
    /// id are constants rather than a counter.
    private static let hotKeyID = EventHotKeyID(signature: OSType(0x4147_544D), id: 1) // 'AGTM'

    init(settings: SettingsModel) {
        self.settings = settings
    }

    /// Install the Carbon handler and register the current keymap's chord (idempotent), then re-register on
    /// `.agtermKeymapChanged` so `keymap.reload` moves the hotkey like it moves every other binding.
    func start() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // the callback captures nothing and reaches the shared controller, like the libghostty C callbacks:
        // a Carbon handler is a plain C function pointer with no context of its own beyond `userData`.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var firedID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            guard status == noErr, firedID.id == GlobalHotkey.hotKeyID.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                // a keypress from another application causes no blur of its own, so it must not be
                // coalesced with one the user's own click just caused.
                QuickTerminalController.shared.toggle(fromGlobalHotkey: true)
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        register(settings.keymap.globalHotkey)
        keymapObserver = NotificationCenter.default.addObserver(
            forName: .agtermKeymapChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.register(self.settings.keymap.globalHotkey)
            }
        }
    }

    /// Unregister the chord, the Carbon handler, and the keymap observer.
    func stop() {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        if let keymapObserver { NotificationCenter.default.removeObserver(keymapObserver) }
        keymapObserver = nil
    }

    /// Replace the registered chord. A nil chord, or one whose base key names no physical position, leaves
    /// the app with no global hotkey — the file's own diagnostics report the second case, so this is silent.
    private func register(_ chord: Chord?) {
        unregister()
        guard let chord, let code = keyCode(forChordKey: chord.key) else { return }
        RegisterEventHotKey(UInt32(code), Self.carbonModifiers(chord.mods), Self.hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// agterm's own modifier set as Carbon's, the only spelling `RegisterEventHotKey` takes.
    private static func carbonModifiers(_ mods: Modifier) -> UInt32 {
        var carbon: UInt32 = 0
        if mods.contains(.command) { carbon |= UInt32(cmdKey) }
        if mods.contains(.option) { carbon |= UInt32(optionKey) }
        if mods.contains(.control) { carbon |= UInt32(controlKey) }
        if mods.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
