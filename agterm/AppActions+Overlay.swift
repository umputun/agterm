import Foundation
import agtermCore

extension AppActions {
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
