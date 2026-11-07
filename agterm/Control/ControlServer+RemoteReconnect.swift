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

    /// catalogScratchStopped parks a remote window row's scratch whose current attach ended while the catalog still
    /// lists it: its screen and shown state stay, and the next answered probe attaches it again. False for a view that
    /// is not such a scratch, so a local scratch keeps its own close.
    @discardableResult
    func catalogScratchStopped(_ view: GhosttySurfaceView) -> Bool {
        guard let session = view.watermarkSession, session.catalogScratch != nil, session.scratchSurface === view else { return false }
        guard let host = session.remoteHost, let mirror = library.store(forSession: session.id)?.remoteActions?.mirror,
              let pane = mirror.scratchAttachmentStopped(of: session.id) else { return true }
        RemoteReconnectBook.shared.wait(pane: pane, session: session.id, host: host, cover: false, now: hudClock())
        startRemoteTick()
        return true
    }

    func tickReconnects() {
        pruneRespawnBook()
        let book = RemoteReconnectBook.shared
        for pane in book.due(now: hudClock()) {
            // a catalog pane reconnects through its pool, whose master comes back once for all its panes
            let pool = book.entries[pane].flatMap { catalogPool(forSession: $0.session) }
            let probe = pool?.leaseOnce()
            guard let entry = book.entries[pane], waitingSurface(pane, in: entry.session) != nil,
                  let argv = try? RemoteSession.probeCommand(host: entry.host, controlPath: probe?.path) else {
                probe.map { pool?.release($0.user) }
                book.cancel(pane: pane)
                continue
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var result = RemoteCommandResult(status: 255, stdout: "", stderr: "no connection to \(entry.host)")
                if let pool, let probe, await !pool.ready(probe.path) {
                    pool.release(probe.user)
                } else {
                    result = await remoteRunner.run(argv, deadline: Self.reconnectProbeDeadline)
                    probe.map { pool?.release($0.user) }
                }
                guard let entry = book.finished(pane: pane, ok: result.status == 0, stderr: result.stderr,
                                                now: hudClock()),
                      let view = waitingSurface(pane, in: entry.session) else { return }
                if let store = library.store(forSession: entry.session), store.session(withID: entry.session)?.catalogScratch == pane {
                    _ = store.remoteActions?.mirror.replaceScratchAttachment(of: entry.session, identity: pane)
                    return
                }
                // a row hidden for undo keeps waiting; finalizing its close lets the next due probe drop it. A catalog
                // row also waits for a fresh catalog, which may have ended it while its host was away
                guard let store = library.store(forSession: entry.session),
                      view.session?.remotePresentation?.binding.catalogOwned != true || store.catalogState == .connected,
                      PaneLead.reconnect?(view, entry.cover) == true else {
                    book.wait(pane: pane, session: entry.session, host: entry.host, cover: entry.cover, now: hudClock())
                    return
                }
                store.remotePaneResumed(pane, forSession: entry.session)
            }
        }
    }

    /// Every waiting pane and dropped stream retries now, not on its backoff.
    func retryRemoteLinksNow() {
        RemoteReconnectBook.shared.retryAllNow(now: hudClock())
        for client in remoteClients.values {
            client.retryNow()
            client.tick()
        }
        tickReconnects()
    }

    /// The surface still holding `pane`, nil once the pane or its row is gone. A row closed within its undo
    /// window still holds it. An ended row's panes keep their last screen and never attach again; only its
    /// surviving scratch does.
    private func waitingSurface(_ pane: UUID, in sessionID: UUID) -> GhosttySurfaceView? {
        guard let session = heldSession(sessionID) else { return nil }
        if session.catalogScratch == pane { return session.scratchSurface as? GhosttySurfaceView }
        guard !session.ended else { return nil }
        let surface = session.paneIdentity == pane ? session.surface
            : session.splitPaneIdentity == pane ? session.splitSurface : nil
        return surface as? GhosttySurfaceView
    }

    func heldSession(_ id: UUID) -> Session? {
        guard let store = library.store(holdingSession: id) else { return nil }
        return store.session(withID: id) ?? store.pendingCloseSession(withID: id)
    }
}
