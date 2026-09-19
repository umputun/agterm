/// Shared contract for overlay command exit-status capture.
///
/// The real command and the status-file path are passed through environment variables so the wrapper
/// never interpolates user command text. The wrapper does not redirect stdout or stderr, so terminal UI
/// programs still render normally while only the exit status is captured.
public enum OverlayCapture {
    public static let cmdEnvKey = "AGTERM_OVL_CMD"
    public static let codeEnvKey = "AGTERM_OVL_CODE"

    public static let shellLine = #"( eval "$AGTERM_OVL_CMD" ); echo $? > "$AGTERM_OVL_CODE""#

    public static func parseExitCode(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// OverlayLaunchContext is what an overlay program starts with, built once on the Mac that owns the session
/// whether the program runs under a local surface or under a viewer's supervising helper. Only the local
/// launch adds its exit-code file; the helper reports the status itself, and takes `TERM` from its pty.
public struct OverlayLaunchContext: Codable, Equatable, Sendable {
    public let command: String
    public let cwd: String
    public let environment: [String: String]

    /// `sessionEnvironment` is the owning session's surface environment. The command rides `AGTERM_OVL_CMD`
    /// so no launcher interpolates it.
    public init(command: String, cwd: String, sessionEnvironment: [String: String]) {
        var environment = sessionEnvironment
        environment[OverlayCapture.cmdEnvKey] = command
        self.command = command
        self.cwd = cwd
        self.environment = environment
    }

    /// The directory an overlay starts in: the caller's `--cwd`, else the session's through the remote rule.
    @MainActor
    public static func cwd(explicit: String?, session: Session, homeDirectory: String) -> String {
        explicit ?? session.localWorkingDirectory(reported: session.effectiveCwd, homeDirectory: homeDirectory)
    }

    /// The environment of a local overlay surface: this context plus the wrapper's exit-code file, and the
    /// body file when the slot holds a HUD.
    public func localEnvironment(codeFile: String, hudFile: String?) -> [String: String] {
        var environment = environment
        environment[OverlayCapture.codeEnvKey] = codeFile
        if let hudFile { environment[HudLayout.fileEnvKey] = hudFile }
        return environment
    }
}
