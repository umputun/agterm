/// Pure builder for the quit-confirmation and window-close alert text. Host-free so the pluralization is
/// unit-tested without an app host; the AppKit `NSAlert`s live in the app target.
public enum QuitPrompt {
    /// The informative line for "Quit Agterm?", reporting how many windows and sessions the quit closes so
    /// the loss is explicit (matching the workspace/window delete confirmations). Singular/plural per count.
    /// `mode` is the launch decision's active mode; settings changes apply after restart.
    public static func message(windows: Int, sessions: Int, mode: RestoreMode) -> String {
        let windowClause = windows == 1 ? "1 window" : "\(windows) windows"
        let sessionClause = sessions == 1 ? "1 session" : "\(sessions) sessions"
        if mode == .live { return "This closes \(windowClause) and \(sessionClause)." }
        return "This closes \(windowClause) and \(sessionClause), ending all running shells."
    }

    /// The informative line for the "Close <window>?" sheet. Live claims no ending, since a window close
    /// only detaches the zmx clients; `mode` is the launch decision's active mode, as for `message`.
    public static func windowCloseMessage(sessions: Int, mode: RestoreMode) -> String {
        let reopen = "The window can be reopened from File ▸ Open Window."
        let plural = sessions == 1 ? "" : "s"
        if mode == .live { return "This closes \(sessions) session\(plural). \(reopen)" }
        return "This ends \(sessions) running session\(plural). \(reopen)"
    }

    /// restartMessage is the informative line for "Restart to update?". Sparkle's relaunch never opens a custom state
    /// directory, so with one nothing reconnects by itself.
    public static func restartMessage(localSessions: Int, remote: Bool, current: RestoreMode, next: RestoreMode,
                                      customStateDirectory: Bool) -> String {
        let keepsLive = current == .live && next == .live
        let one = localSessions == 1
        let count = one ? "1 session" : "\(localSessions) sessions"
        var lines: [String] = []
        if localSessions > 0 {
            if keepsLive && customStateDirectory {
                lines.append("\(count) \(one ? "keeps" : "keep") running.")
            } else if keepsLive {
                lines.append("\(count) \(one ? "keeps running and reconnects" : "keep running and reconnect") after the restart.")
            } else if current == .live && customStateDirectory {
                lines.append("\(count) \(one ? "ends" : "end") when agterm next opens this state directory.")
            } else if current == .live {
                lines.append("\(count) \(one ? "ends" : "end") at the next launch.")
            } else {
                lines.append("This ends the running shells in \(count).")
            }
        }
        if remote {
            let hostReconnects = customStateDirectory ? "" : " and reconnect after the restart"
            lines.append("Sessions from other hosts keep running there\(hostReconnects).")
        }
        if customStateDirectory, remote || (keepsLive && localSessions > 0) {
            lines.append("Reopen agterm with the same AGTERM_STATE_DIR to reconnect.")
        }
        return lines.joined(separator: " ")
    }
}
