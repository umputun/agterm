import agtermCore
import AppKit

/// Local monitor for the undo-close chord. It deliberately avoids a menu `keyboardShortcut` so native
/// text undo keeps working in rename fields, palettes, and settings controls.
@MainActor
final class UndoCloseShortcut {
    private let actions: AppActions
    private var monitor: Any?

    init(actions: AppActions) {
        self.actions = actions
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard actions.store?.pendingCloseSummary != nil else { return false }
        guard NSApp.keyWindow?.firstResponder is NSText == false else { return false }
        guard let chord = chord(from: event) else { return false }
        let expected = actions.settingsModel?.keymap.equivalent(for: .undoClose) ?? BuiltinAction.undoClose.defaultChord
        guard chord == expected else { return false }
        actions.undoClose()
        return true
    }

    private func chord(from event: NSEvent) -> Chord? {
        var mods: Modifier = []
        let flags = event.modifierFlags
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }

        let key = namedKey(forKeyCode: event.keyCode) ?? event.charactersIgnoringModifiers?.lowercased()
        guard let key, key.count == 1 || bindableNamedKeys.contains(key) else { return nil }
        return Chord(mods: mods, key: key)
    }
}
