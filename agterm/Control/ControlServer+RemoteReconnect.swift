import Foundation
import agtermCore

/// Attaches remote panes again after their ssh lost the connection. `RemoteReconnectBook` owns the schedule;
/// this runs its probes on the remote tick and hands a pane whose host answered to `PaneLead.reconnect`.
extension ControlServer {
    static let reconnectProbeDeadline: TimeInterval = 10

    func waitToReconnect(_ view: GhosttySurfaceView, cover: Bool) {
        guard let session = view.session, let host = session.remoteHost, heldSession(session.id) === session,
              let pane = session.surface === view ? session.paneIdentity
                  : session.splitSurface === view ? session.splitPaneIdentity : nil else { return }
        RemoteReconnectBook.shared.wait(pane: pane, session: session.id, host: host, cover: cover, now: hudClock())
        startRemoteTick()
    }

    func tickReconnects() {
        let book = RemoteReconnectBook.shared
        for pane in book.due(now: hudClock()) {
            guard let entry = book.entries[pane], waitingSurface(pane, in: entry.session) != nil,
                  let argv = try? RemoteSession.probeCommand(host: entry.host) else {
                book.cancel(pane: pane)
                continue
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await remoteRunner.run(argv, deadline: Self.reconnectProbeDeadline)
                guard let entry = book.finished(pane: pane, ok: result.status == 0, now: hudClock()),
                      let view = waitingSurface(pane, in: entry.session) else { return }
                // a row hidden for undo keeps waiting; finalizing its close lets the next tick drop it
                guard let store = library.store(forSession: entry.session), PaneLead.reconnect?(view, entry.cover) == true else {
                    book.wait(pane: pane, session: entry.session, host: entry.host, cover: entry.cover, now: hudClock())
                    return
                }
                store.remotePaneResumed(pane, forSession: entry.session)
            }
        }
    }

    /// The surface still holding `pane`, nil once the pane or its row is gone. A row closed within its undo
    /// window still holds it.
    private func waitingSurface(_ pane: UUID, in sessionID: UUID) -> GhosttySurfaceView? {
        guard let session = heldSession(sessionID) else { return nil }
        let surface = session.paneIdentity == pane ? session.surface
            : session.splitPaneIdentity == pane ? session.splitSurface : nil
        return surface as? GhosttySurfaceView
    }

    private func heldSession(_ id: UUID) -> Session? {
        guard let store = library.store(holdingSession: id) else { return nil }
        return store.session(withID: id) ?? store.pendingCloseSession(withID: id)
    }
}
