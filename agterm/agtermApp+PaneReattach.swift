import agtermCore
import AppKit

extension agtermApp {
    /// An attach that stopped, on its exit prompt (a failed take-over included) or waiting to reconnect:
    /// no client is left to report a role, and a cover would hide the notice saying what happened.
    @MainActor
    static func remotePaneStopped(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID, library: WindowLibrary,
                                  attach: RemoteAttachLines?) {
        if let pane = UUID(uuidString: view.paneToken) {
            ZmxLeadBook.shared.forget(pane: pane)
            store.leadRoleChanged()
        }
        Self.handleRemotePaneHeld(view, store: store, sessionID: sessionID, library: library, attach: attach)
    }

    /// Replaces `old` with a fresh attach of the same pane in the same slot. None of the pane's close paths
    /// run: the session, the daemon and the pane identity all stay, so the program inside keeps the
    /// `AGTERM_PANE_ID` it was started with.
    @MainActor @discardableResult
    static func reattachPane(_ old: GhosttySurfaceView, claim: Bool, cover: Bool = true, reclaim: String? = nil,
                             services: SurfaceServices) -> Bool {
        let lead = ZmxLeadAttachment(claim: claim, reclaim: reclaim)
        if let owner = old.scratchOwner { return reattachScratch(old, session: owner, lead: lead, cover: cover, services: services) }
        guard let session = old.session,
              let identity = old.isSplitPane ? session.splitPaneIdentity : session.paneIdentity,
              let launch = PaneReattach.launch(replacing: old, session: session, identity: identity, lead: lead)
        else { return false }
        return replacePane(old, launch: launch, lead: lead, cover: cover, services: services) != nil
    }

    /// reattachScratch swaps a Live scratch's surface for a fresh attach of its daemon, keeping its shown state and
    /// identity; the bumped `scratchGeneration` remounts the host.
    @MainActor
    private static func reattachScratch(_ old: GhosttySurfaceView, session: Session, lead: ZmxLeadAttachment, cover: Bool,
                                        services: SurfaceServices) -> Bool {
        guard let identity = session.scratchClientIdentity, old.paneToken == identity.uuidString,
              let store = services.library.store(forSession: session.id),
              let launch = old.backedByZmx ? PaneReattach.launch(replacing: old, session: session, identity: identity, lead: lead)
                  : session.originScratch.flatMap({ PaneReattach.originScratch(replacing: old, session: session, identity: $0, lead: lead) })
        else { return false }
        let fontSize = old.currentFontSize() ?? session.fontSize
        let view = GhosttySurfaceView(workingDirectory: launch.workingDirectory, fontSize: fontSize.map(Float.init),
                                      command: launch.command, waitAfterCommand: launch.wait,
                                      env: launch.environment, backedByZmx: old.backedByZmx)
        wireScratch(view, session: session, store: store, actions: services.actions)
        ZmxLeadBook.shared.begin(lead, pane: identity, reattaching: cover)
        // the old client's exit must not close the scratch the new one now owns
        _ = old.claimProcessExit()
        let hadFocus = old.window?.firstResponder === old
        if session.searchSurface === old { session.clearSearch() }
        session.scratchSurface = view
        session.scratchGeneration += 1
        old.retireSurface()
        if hadFocus { view.focusAfterReparent() }
        return true
    }
}
