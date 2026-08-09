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
    /// A nil `socketPath` OMITS `AGTERM_SOCKET` rather than emitting an empty one: this instance is not
    /// serving a socket, and the resolved default would reach a different app's.
    public static func session(sessionID: UUID, windowID: UUID?, workspaceID: UUID?,
                               socketPath: String?, programVersion: String,
                               pane: StatusPane? = nil, paneToken: String? = nil) -> [String: String] {
        var env = terminalIdentity(programVersion: programVersion).merging([
            "AGTERM_ENABLED": "1",
            "AGTERM_SESSION_ID": sessionID.uuidString,
        ]) { _, agtermValue in agtermValue }
        if let socketPath {
            env["AGTERM_SOCKET"] = socketPath
        }
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

    /// Environment for a window's quick terminal, which is not part of the session tree.
    public static func quickTerminal(windowID: UUID, socketPath: String?,
                                     programVersion: String) -> [String: String] {
        var env = terminalIdentity(programVersion: programVersion).merging([
            "AGTERM_ENABLED": "1",
            "AGTERM_WINDOW_ID": windowID.uuidString,
        ]) { _, agtermValue in agtermValue }
        if let socketPath {
            env["AGTERM_SOCKET"] = socketPath
        }
        return env
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
