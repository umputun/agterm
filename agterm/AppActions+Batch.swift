import agtermCore
import AppKit
import SwiftUI

extension AppActions {
    /// Close one or more sidebar-selected sessions in a window-local store, honoring the same confirmation
    /// and undo-grace settings as the single-session Close command.
    func closeSessions(_ ids: [UUID], in store: AppStore) {
        let sessions = ids.compactMap { store.session(withID: $0) }
        guard !sessions.isEmpty else { return }
        if sessions.count == 1 {
            closeSession(sessions[0].id, in: store)
            return
        }
        guard confirmCloseSessions(sessions) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            if closeGraceUndoEnabled {
                _ = store.softCloseSessions(sessions.map(\.id))
            } else {
                for session in sessions {
                    store.closeSession(session.id)
                }
            }
        }
        focusActiveSession()
    }

    private func confirmCloseSessions(_ sessions: [Session]) -> Bool {
        guard settingsModel?.settings.confirmCloseSession == true,
              !ContentView.shouldBypassCloseConfirmation else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(sessions.count) Sessions?"
        alert.informativeText = closeGraceUndoEnabled
            ? "The sessions will close after a short undo window."
            : "The sessions will close immediately and can be reopened from File > Open Recent."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// sidebar context menus pass their own store so a background window never routes through the
    /// frontmost store by accident.
    func toggleFlags(_ sessionIDs: [UUID], in store: AppStore) {
        let sessions = sessionIDs.compactMap { store.session(withID: $0) }
        guard !sessions.isEmpty else { return }
        let allFlagged = sessions.allSatisfy(\.flagged)
        store.setFlag(!allFlagged, forSessions: sessions.map(\.id))
    }
}
