import Foundation
import agtermCore

/// The job connections themselves are agtermCore's `OverlayJobStreamHost`, shared with agterm-server; this Mac adds
/// the overlay open that registers a job for its presenter.
extension ControlServer: OverlayJobStreamHost {
    func claimOverlayJob(_ job: String) -> ControlResponse { claimJobStream(job) }

    func claimOverlayJob(_ job: String, token: String?) -> ControlResponse { claimJobStream(job, token: token) }

    /// Hands an overlay to the viewer presenting the session, or returns nil for the caller to handle locally.
    /// The launch context is built as a local overlay's would be, from this Mac's session.
    func openRemoteOverlay(in store: AppStore, sessionID: UUID, options: ControlSessionOverlayOpenOptions) -> ControlResponse? {
        guard let session = store.session(withID: sessionID) else { return nil }
        let context = OverlayLaunchContext(
            command: options.command,
            cwd: OverlayLaunchContext.cwd(explicit: options.cwd, session: session, homeDirectory: NSHomeDirectory()),
            sessionEnvironment: sessionEnvironment(for: session, in: store))
        switch store.openRemoteOverlay(sessionID, options: options, context: context) {
        case .notPresented:
            return nil
        case .slotTaken:
            return ControlResponse(ok: false, error: options.pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen)
        case .paneMissing:
            return ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible)
        case .tooLarge:
            return ControlResponse(ok: false, error: OverlayResultError.tooLarge)
        case .pointsUnsupported:
            return ControlResponse(ok: false, error: OverlayPointError.remote)
        case .opened:
            scheduleOverlayJobExpiry(after: OverlayJobs.launchWindow)
            return ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString))
        }
    }

    /// What a program started for `session` sees on this Mac, the same identities a local overlay gets.
    private func sessionEnvironment(for session: Session, in store: AppStore) -> [String: String] {
        SurfaceEnvironment.session(sessionID: session.id, windowID: library.windowID(for: store),
                                   workspaceID: store.workspace(forSession: session.id)?.id,
                                   socketPath: resolvedSocketPath, programVersion: identity.version)
    }
}
