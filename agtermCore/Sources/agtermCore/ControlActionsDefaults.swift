import Foundation

// Default `ControlActions` implementations, kept out of `ControlDispatcher.swift` so that file stays
// inside the 1000-line limit.
public extension ControlActions {
    /// Defaults so a conformer outside this repo — the `agterm-linux` fork consumes `agtermCore` as a
    /// library — keeps building when a Mac-only command joins the protocol. Each refuses by name rather
    /// than answering an empty success, which would be indistinguishable from a working command.
    func readRestoreMode() -> ControlResponse {
        ControlResponse(ok: false, error: ControlActionsUnsupported.message("restore.mode"))
    }

    func setRestoreMode(_: RestoreMode) -> ControlResponse {
        ControlResponse(ok: false, error: ControlActionsUnsupported.message("restore.mode"))
    }

    func listZmxDaemons() -> ControlResponse {
        ControlResponse(ok: false, error: ControlActionsUnsupported.message("zmx.list"))
    }

    func pruneZmxDaemons() -> ControlResponse {
        ControlResponse(ok: false, error: ControlActionsUnsupported.message("zmx.prune"))
    }

    func killZmxDaemon(target _: String, window _: String?, pane _: ZmxPaneRole) -> ControlResponse {
        ControlResponse(ok: false, error: ControlActionsUnsupported.message("zmx.kill"))
    }

    func splitSession(_ target: String?, window: String?, mode: String?, axis _: SplitAxis?) -> ControlResponse {
        splitSession(target, window: window, mode: mode)
    }

    func swapSessionPanes(_: String?, window _: String?) async -> ControlResponse {
        ControlResponse(ok: false, error: "session.swap is not supported by this host")
    }

    /// Not `ControlActionsUnsupported.message`, which says "on this platform": the divider exists wherever
    /// there is a sidebar, so a host refusing this has not implemented the command rather than lacking the
    /// thing it moves.
    func setSidebarWidth(_: Double, window _: String?) -> ControlResponse {
        ControlResponse(ok: false, error: "sidebar.width is not supported by this control host")
    }

    func setSessionContext(_: String?, window _: String?, context _: String?) -> ControlResponse {
        ControlResponse(ok: false, error: ControlActionsUnsupported.message("session.context"))
    }
}
