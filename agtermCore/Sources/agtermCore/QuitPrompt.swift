import Foundation

/// Pure builder for the quit-confirmation alert text. Host-free so the pluralization is unit-tested
/// without an app host; the AppKit `NSAlert` lives in the app target's `AppDelegate`.
public enum QuitPrompt {
    /// The informative line for "Quit Agterm?", reporting how many windows and sessions the quit
    /// closes so the loss is explicit (matching the workspace/window delete confirmations). Singular
    /// and plural agree per count.
    public static func message(windows: Int, sessions: Int) -> String {
        let windowClause = windows == 1 ? "1 window" : "\(windows) windows"
        let sessionClause = sessions == 1 ? "1 session" : "\(sessions) sessions"
        return "This closes \(windowClause) and \(sessionClause), ending all running shells."
    }
}
