import agtermCore
import AppKit

extension agtermApp {
    /// LiveScratch is a local scratch's daemon attach: the identity it names, its lead, the spawn line and environment.
    struct LiveScratch {
        let identity: UUID
        let lead: ZmxLeadAttachment
        let command: String
        let environment: [String: String]
    }

    /// makeScratchSurface builds a session's scratch: a login shell, or the run-once `session.scratchCommand`, alive
    /// while hidden. It is not wired as a pane (`view.session` stays nil), so its title and cwd never reach the row.
    @MainActor
    static func makeScratchSurface(for session: Session, store: AppStore, env: [String: String],
                                   suppressAutoFocus: Bool, actions: AppActions,
                                   requested: RestoreMode = GhosttyApp.shared.requestedRestoreMode,
                                   active: RestoreMode = GhosttyApp.shared.launchRestoreMode) -> GhosttySurfaceView {
        // re-shows are focused via the `scratchActive` onChange (which also defers to those covers).
        // scratchCommand is run-once: read it for this spawn, then clear so a local scratch's post-exit respawn is a shell.
        let command = session.scratchCommand
        session.scratchCommand = nil
        let cwd = session.localWorkingDirectory(reported: session.effectiveCwd, homeDirectory: NSHomeDirectory())
        // a remote row's scratch can be its server's or origin's, whose directory is known only once it reports one
        let originScratch = session.originScratch
        if originScratch == nil { session.scratchCwd = cwd }
        let live = originScratch == nil
            ? liveScratch(for: session, store: store, env: env, command: command, requested: requested, active: active) : nil
        let originToken = originScratch == nil ? nil : session.scratchClientIdentity
        let view = GhosttySurfaceView(workingDirectory: cwd, fontSize: session.fontSize.map(Float.init),
                                      command: live?.command ?? command, autoFocus: !suppressAutoFocus,
                                      env: live?.environment
                                          ?? env.merging(originToken.map { ["AGTERM_PANE_ID": $0.uuidString] } ?? [:]) { $1 },
                                      backedByZmx: live != nil)
        if let live { ZmxLeadBook.shared.begin(live.lead, pane: live.identity) }
        Self.wireScratch(view, session: session, store: store, actions: actions)
        return view
    }

    /// wireScratch installs the callbacks every scratch surface carries, from the factory or a reattach.
    @MainActor
    static func wireScratch(_ view: GhosttySurfaceView, session: Session, store: AppStore, actions: AppActions) {
        view.watermarkSession = session
        let sessionID = session.id
        view.onExit = { [weak view] in
            if let view, PaneLead.scratchStopped?(view) == true { return }
            store.closeScratch(sessionID)
        }
        Self.wireStatusClear(view, store: store, sessionID: sessionID, fixedPane: .scratch)
        // same idle-timer reset as the overlay: an idle auto-follow fire must not hide the scratch mid-typing.
        view.onUserInput = { _ in store.noteUserActivity() }
        // the scratch is searchable (⌘F), pinned to the same session as the panes: unlike the overlay/quick
        // terminal it stays alive across hides, so a bar over it is safe.
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, actions: actions)
    }

    /// liveScratch is a local scratch's attach to its daemon in Live sessions mode, which `command` creates when the
    /// daemon is gone. Nil outside Live, where a launch that did not request Live also forgets a saved daemon, and a
    /// requested-Live fallback keeps it for the next Live launch.
    @MainActor
    static func liveScratch(for session: Session, store: AppStore, env: [String: String], command: String?,
                            requested: RestoreMode = GhosttyApp.shared.requestedRestoreMode,
                            active: RestoreMode = GhosttyApp.shared.launchRestoreMode) -> LiveScratch? {
        guard ZmxLaunch.wrapsLocally(mode: active, session: session) else {
            if requested != .live { store.forgetSavedScratch(session.id) }
            return nil
        }
        let identity = session.localScratchIdentity ?? UUID()
        let lead = ZmxLeadAttachment(claim: false)
        guard let zmx = ZmxLaunch.configuration(paneIdentity: identity, pane: "scratch",
                                                environment: env.merging(["AGTERM_PANE_ID": identity.uuidString]) { $1 },
                                                lead: lead) else { return nil }
        store.recordLiveScratch(session.id, identity: identity)
        return LiveScratch(identity: identity, lead: lead,
                           command: ZmxSupport.attachCommand(zmx, replaying: nil, paneCommand: command, denylist: []),
                           environment: zmx.environment)
    }
}
