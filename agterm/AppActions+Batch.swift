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

    /// Move one session to another OPEN window, carrying its live shell. Cross-window, so it goes through
    /// the library rather than a store, and the modal gate reads the SOURCE window — a background sidebar's
    /// menu must not be judged by whatever the frontmost window has up. The destination's selection is left
    /// alone, matching the control API's plain `--to-window`.
    @discardableResult
    func moveSession(_ sessionID: UUID, toWindow windowID: WindowInfo.ID) -> Bool {
        guard uiActionsEnabled(for: library.windowID(forSession: sessionID)) else { return false }
        return library.moveSession(sessionID, toWindow: windowID)
    }

    /// Batch form for a multi-row sidebar selection; returns how many moved. Order is preserved because each
    /// session appends to the destination workspace in turn.
    @discardableResult
    func moveSessions(_ sessionIDs: [UUID], toWindow windowID: WindowInfo.ID) -> Int {
        sessionIDs.reduce(0) { moved, id in moved + (moveSession(id, toWindow: windowID) ? 1 : 0) }
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
