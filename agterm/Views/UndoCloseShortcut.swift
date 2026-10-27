import agtermCore
import AppKit

/// Local monitor for the undo-close chord. It deliberately avoids a menu `keyboardShortcut` so native
/// text undo keeps working in rename fields, palettes, settings controls, and HTML pages.
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
        guard !Self.yieldsChord(to: NSApp.keyWindow?.firstResponder) else { return false }
        guard let chord = chord(from: event), matchesUndoCloseChord(chord) else { return false }
        actions.undoClose()
        return true
    }

    /// Whether `responder` keeps the chord for its own undo: a native text field or a focused HTML page.
    /// No session is passed, so a page that merely covers the session while focus is elsewhere does not.
    static func yieldsChord(to responder: NSResponder?) -> Bool {
        responder is NSText || AppActions.htmlPageOwnsKeys(responder: responder, session: nil)
    }

    /// Whether `chord` is what `undo_close` is bound to right now. A wired keymap answering nil means a `map`
    /// line left the action explicitly unbound, so NOTHING matches — only an unwired settings model falls back
    /// to the shipped ⌘Z. Internal so a hosted test can drive the decision without a pending close.
    func matchesUndoCloseChord(_ chord: Chord) -> Bool {
        let expected = actions.settingsModel.map { $0.keymap.equivalent(for: .undoClose) }
            ?? BuiltinAction.undoClose.defaultChord
        return expected == chord
    }

    func chord(from event: NSEvent) -> Chord? {
        // unlike `CustomCommandRunner.chord(from:)` the produced character here KEEPS shift (`shift+/` reports
        // `?`), so a shifted-symbol chord does not match on a Latin layout — pre-existing, and why this
        // monitor's `NSEvent` seam is the testable one (a synthesized event reports this accessor verbatim).
        guard let chord = event.keymapChord(produced: event.charactersIgnoringModifiers),
              chord.key.count == 1 || bindableNamedKeys.contains(chord.key) else { return nil }
        return chord
    }
}
