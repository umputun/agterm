import Foundation

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
