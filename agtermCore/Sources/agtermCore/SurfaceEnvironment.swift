import Foundation

/// Pure builders for the agterm identity and `AGTERM_*` values injected into spawned shells.
/// The platform surface owns shell creation; this keeps the variable set testable.
public enum SurfaceEnvironment {
    /// Environment for a session-owned surface: main pane, split pane, overlay, or scratch. `pane`, when
    /// non-nil, adds `AGTERM_PANE` so the hook wrapper can forward `--pane` and a status set from a
    /// background pane records which surface blocked; overlay surfaces pass nil (nil→main). `paneToken`,
    /// when non-empty, adds `AGTERM_PANE_ID` — the surface's STABLE spawn identity
    /// (`TerminalSurface.paneToken`), which the hook forwards as `--pane-id` so the status handler resolves
    /// the LIVE role instead of the stale baked `AGTERM_PANE` after a promote + re-split (#199).
    /// `socketPath` is always emitted, never omitted: consumers treat an absent `AGTERM_SOCKET` as
    /// "resolve the default", which is another instance's. `ControlServer` supplies an unbindable path
    /// when it does not own one.
    public static func session(sessionID: UUID, windowID: UUID?, workspaceID: UUID?,
                               socketPath: String, programVersion: String,
                               pane: StatusPane? = nil, paneToken: String? = nil) -> [String: String] {
        var env = terminalIdentity(programVersion: programVersion).merging([
            "AGTERM_ENABLED": "1",
            "AGTERM_SESSION_ID": sessionID.uuidString,
            "AGTERM_SOCKET": socketPath,
        ]) { _, agtermValue in agtermValue }
        if let windowID {
            env["AGTERM_WINDOW_ID"] = windowID.uuidString
        }
        if let workspaceID {
            env["AGTERM_WORKSPACE_ID"] = workspaceID.uuidString
        }
        if let pane {
            env["AGTERM_PANE"] = pane.rawValue
        }
        if let paneToken, !paneToken.isEmpty {
            env["AGTERM_PANE_ID"] = paneToken
        }
        return env
    }

    /// Environment for the quick terminal, which is neither part of the session tree nor owned by a window —
    /// it is one detached panel per app, so it carries no window id and an untargeted `agtermctl` run from it
    /// resolves the active window like any other caller.
    public static func quickTerminal(socketPath: String, programVersion: String) -> [String: String] {
        terminalIdentity(programVersion: programVersion).merging([
            "AGTERM_ENABLED": "1",
            "AGTERM_SOCKET": socketPath,
        ]) { _, agtermValue in agtermValue }
    }

    private static func terminalIdentity(programVersion: String) -> [String: String] {
        // embedded libghostty defaults these to Ghostty, then reapplies the surface env as overrides.
        // identify the actual host so Ghostty-aware shell tools do not invoke a standalone Ghostty.app.
        [
            "TERM_PROGRAM": "agterm",
            "TERM_PROGRAM_VERSION": programVersion,
        ]
    }
}
