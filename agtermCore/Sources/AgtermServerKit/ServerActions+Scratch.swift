import Foundation
import agtermCore

extension ServerActions {
    /// scratchSession shows or hides a session's scratch, a daemon of its own that outlives a hide: `on` with a
    /// command replaces the scratch that runs, shown or hidden, and `on` without one shows the one there is.
    public func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse {
        withSession(target, window: window) { session in
            guard let parsed = ControlToggleMode.parse(mode) else {
                return ControlResponse(ok: false, error: "invalid scratch mode: \(mode ?? "toggle")")
            }
            guard parsed.desiredValue(current: session.scratchDaemon?.shown == true) else {
                session.scratchDaemon?.shown = false
                return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
            }
            if let command, !command.isEmpty, let running = session.scratchDaemon {
                store.dropScratchDaemon(session.id)
                panes.end([running.identity])
            }
            if session.scratchDaemon == nil {
                let identity = UUID()
                let workspace = store.sessionLocation(ofSession: session.id)?.workspace
                var start = ServerPanes.Start(identity: identity, session: session, workspace: workspace, pane: .scratch,
                                              command: command?.isEmpty == false ? command : nil, directory: session.effectiveCwd)
                start.scratch = true
                if let refusal = panes.start(start) { return ControlResponse(ok: false, error: refusal) }
                session.scratchDaemon = Session.ScratchDaemon(identity: identity, shown: true)
            } else {
                session.scratchDaemon?.shown = true
            }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    /// scratchRefusal refuses an operation decided on a scratch `target` no longer has: `expected` is its identity,
    /// or `none` for a session that had no scratch then.
    func scratchRefusal(_ target: String?, expected: String) -> String? {
        guard case .success(let session) = resolveSession(target) else { return nil }
        let current = session.scratchDaemon?.identity.uuidString.lowercased() ?? "none"
        return current == expected.lowercased() ? nil : "the session's scratch changed; take the catalog again"
    }
}
