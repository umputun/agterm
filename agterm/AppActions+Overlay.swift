import AppKit
import agtermCore

extension AppActions {
    /// toggleOverlays hides every program and page of the active session while any is shown, else shows them
    /// all: the menu, palette, title-bar button and `toggle_overlay` chord share it with `session.overlay.toggle`.
    func toggleOverlays() {
        guard uiActionsEnabled, let store, let session = store.activeSession else { return }
        store.toggleOverlaysHidden(session.id, pane: nil)
    }

    func answerHiddenOverlayRefusal(_ id: UUID) {
        guard let store, store.session(withID: id).map({ !$0.sessionSlotShown }) == true else { return }
        // a pane-held cover still needs a refusal signal
        NSSound.beep()
        store.revealSessionOverlay(id)
    }

    /// closeConfirmationText is the close alert's body for `sessions`, naming the hidden overlays that go with
    /// them: a hidden overlay is out of sight, so the alert is the last place it can be noticed.
    func closeConfirmationText(for sessions: [Session], companions: [Session] = []) -> String {
        let plural = sessions.count > 1
        let noun = plural ? "sessions" : "session"
        var text = closeGraceUndoEnabled
            ? "The \(noun) will close after a short undo window."
            : "The \(noun) will close immediately and can be reopened from File > Open Recent."
        if !companions.isEmpty {
            text += " Companions close too: \(companions.map(\.displayName).joined(separator: ", "))."
        }
        guard (sessions + companions).contains(where: { !$0.hiddenOverlayNames.isEmpty }) else { return text }
        return text + (plural || !companions.isEmpty ? " Their hidden overlays close with them." : " Its hidden overlays close with it.")
    }
}
