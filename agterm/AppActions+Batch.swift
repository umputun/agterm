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
        let selected = Set(ids)
        let companions = sessions.flatMap { store.companions(of: $0.id) }.filter { !selected.contains($0.id) }
        guard confirmCloseSessions(sessions, companions: companions) else { return }
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

    private func confirmCloseSessions(_ sessions: [Session], companions: [Session]) -> Bool {
        guard settingsModel?.settings.confirmCloseSession == true,
              !ContentView.shouldBypassCloseConfirmation else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(sessions.count) Sessions?"
        alert.informativeText = closeConfirmationText(for: sessions, companions: companions)
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
