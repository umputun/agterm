import agtermCore
import AppKit

extension agtermApp {
    /// An attach that stopped, on its exit prompt (a failed take-over included) or waiting to reconnect:
    /// no client is left to report a role, and a cover would hide the line saying what happened.
    @MainActor
    static func remotePaneStopped(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID, library: WindowLibrary) {
        if let pane = UUID(uuidString: view.paneToken) {
            ZmxLeadBook.shared.forget(pane: pane)
            store.leadRoleChanged()
        }
        Self.handleRemotePaneHeld(view, store: store, sessionID: sessionID, library: library)
    }

    /// Replaces `old` with a fresh attach of the same pane in the same slot. None of the pane's close paths
    /// run: the session, the daemon and the pane identity all stay, so the program inside keeps the
    /// `AGTERM_PANE_ID` it was started with.
    @MainActor @discardableResult
    static func reattachPane(_ old: GhosttySurfaceView, claim: Bool, cover: Bool = true, services: SurfaceServices) -> Bool {
        let lead = ZmxLeadAttachment(claim: claim)
        guard let session = old.session,
              let identity = old.isSplitPane ? session.splitPaneIdentity : session.paneIdentity,
              let launch = PaneReattach.launch(replacing: old, session: session, identity: identity, lead: lead)
        else { return false }
        return replacePane(old, launch: launch, lead: lead, cover: cover, services: services) != nil
    }
}
