import AppKit
import agtermCore

extension AppActions {
    /// toggleOverlays hides every program and page of the active session while any is shown, else shows them
    /// all: the menu, palette, title-bar button and `toggle_overlay` chord share it with `session.overlay.toggle`.
    func toggleOverlays() {
        guard uiActionsEnabled, let store, let session = store.activeSession else { return }
        store.toggleOverlaysHidden(session.id, pane: nil)
    }

    /// beepIfHiddenOverlayRefused answers an editor open the session slot refused because a hidden overlay holds
    /// it, the one refusal with nothing on screen to explain it. Visibility is left alone.
    func beepIfHiddenOverlayRefused(_ id: UUID) {
        if store?.session(withID: id)?.overlayHidden == true { NSSound.beep() }
    }

    /// closeConfirmationText is the close alert's body for `sessions`, naming the hidden overlays that go with
    /// them: a hidden overlay is out of sight, so the alert is the last place it can be noticed.
    func closeConfirmationText(for sessions: [Session]) -> String {
        let plural = sessions.count > 1
        let noun = plural ? "sessions" : "session"
        let base = closeGraceUndoEnabled
            ? "The \(noun) will close after a short undo window."
            : "The \(noun) will close immediately and can be reopened from File > Open Recent."
        guard sessions.contains(where: { !$0.hiddenOverlayNames.isEmpty }) else { return base }
        return base + (plural ? " Their hidden overlays close with them." : " Its hidden overlays close with it.")
    }
}
