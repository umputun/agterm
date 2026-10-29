import Darwin
import Foundation
import agtermCore

/// Carries a viewer across its origin respawning a parent's shell. The origin publishes a pane's respawn once a
/// different live leader runs under the same daemon name; a viewer whose attach exited cleanly attaches again,
/// attach-only, when the origin's count passed the one it last attached to. `RemoteRespawnBook` owns the join.
extension ControlServer {
    static let respawnLeaderWait: Duration = .seconds(10)

    /// priorLeader is the daemon's leader as last listed, read before the respawn replaces it.
    func priorLeader(daemon: String) -> pid_t? {
        zmxForegroundResolver?.cachedLeader(sessionName: daemon)
    }

    /// ownerRespawned publishes `daemon`'s respawn to the session's viewers once a live leader other than `prior`
    /// runs under its name; nothing is published when none shows up in time.
    func ownerRespawned(session: UUID, daemon: String, prior: pid_t?) {
        guard let client = zmxClient else { return }
        Task { @MainActor [weak self] in
            guard let self, let pid = await shell(daemon: daemon, otherThan: prior, client: client, within: Self.respawnLeaderWait),
                  kill(pid, 0) == 0 else { return }
            var counts = respawnGenerations[session] ?? [:]
            let generation = (counts[daemon] ?? 0) + 1
            counts[daemon] = generation
            respawnGenerations[session] = counts
            presentationHub.publish(.respawn(PresentationRespawns(epoch: originEpoch, generations: [daemon: generation])),
                                    session: session)
        }
    }

    /// applyRemoteRespawns feeds what the origin reported into the book, for each local pane of the row; a frame
    /// names one daemon and leaves the others as they were.
    func applyRemoteRespawns(_ respawns: PresentationRespawns, seed: Bool, forSession id: UUID) {
        guard let session = library.store(forSession: id)?.session(withID: id),
              let binding = session.remotePresentation?.binding else { return }
        for (pane, daemon) in binding.daemonsByPane {
            guard seed || respawns.generations[daemon] != nil else { continue }
            let mark = RemoteRespawnBook.Mark(epoch: respawns.epoch, generation: respawns.generations[daemon] ?? 0)
            if RemoteRespawnBook.shared.observe(mark, pane: pane, session: id, seed: seed) { reattachRespawned(pane, in: session) }
        }
        startRemoteTick()
    }

    /// remotePaneHeld is a remote pane's clean exit; it attaches again when the origin respawned the pane.
    func remotePaneHeld(_ view: GhosttySurfaceView) {
        guard let session = view.session, session.remotePresentation != nil,
              let pane = session.surface === view ? session.paneIdentity
                  : session.splitSurface === view ? session.splitPaneIdentity : nil else { return }
        if RemoteRespawnBook.shared.held(pane: pane, session: session.id) { reattachRespawned(pane, in: session) }
    }

    /// pruneRespawnBook drops the entries of panes no open or soft-closed row holds any more. Run from the tick only.
    func pruneRespawnBook() {
        RemoteRespawnBook.shared.prune { pane, session in
            guard let row = heldSession(session) else { return false }
            return row.paneIdentity == pane || row.splitPaneIdentity == pane
        }
    }

    // the new attach records its own attempt in `replacePane`; one that could not even start leaves the prompt
    private func reattachRespawned(_ pane: UUID, in session: Session) {
        let surface = session.paneIdentity == pane ? session.surface
            : session.splitPaneIdentity == pane ? session.splitSurface : nil
        guard let view = surface as? GhosttySurfaceView else { return }
        _ = PaneLead.reconnect?(view, true)
    }
}
