import Foundation

/// Which surface within a session fired a terminal notification. Encoded into the notification's
/// identity so a click can focus the exact pane, not just the session.
public enum PaneRole: String, Codable, Sendable, CaseIterable {
    case main
    case split
    case overlay
}

/// Pure helpers for terminal desktop notifications (OSC 9 / 777): the coalescing identity tying a system
/// notification to a session/pane, and the suppression rule. `NotificationManager` builds the request.
public enum TerminalNotification {
    /// The notification's identity, `"<windowID>:<sessionID>:<paneRole>"`. Repeats from the same pane share
    /// it, so the OS replaces the prior banner instead of stacking duplicates. The windowID lets a click
    /// reopen the owning window if it closed since the banner fired (the firing surface is always in an
    /// open window at fire time, so it is known).
    public static func identity(windowID: UUID, sessionID: UUID, pane: PaneRole) -> String {
        "\(windowID.uuidString):\(sessionID.uuidString):\(pane.rawValue)"
    }

    /// The identity of a control `notify` banner, `"<windowID>:<sessionID>:notify"`. One slot per session,
    /// apart from every pane's, so a terminal banner never replaces a note posted on purpose. Repeated
    /// notes still replace each other.
    public static func controlIdentity(windowID: UUID, sessionID: UUID) -> String {
        "\(windowID.uuidString):\(sessionID.uuidString):\(controlSuffix)"
    }

    /// Every identity a session's banners can carry: each pane's plus the control slot.
    public static func sessionIdentities(windowID: UUID, sessionID: UUID) -> [String] {
        PaneRole.allCases.map { identity(windowID: windowID, sessionID: sessionID, pane: $0) }
            + [controlIdentity(windowID: windowID, sessionID: sessionID)]
    }

    /// Decodes a banner identity into the click target, or nil if malformed: two colon-free UUIDs, window
    /// id first, then a pane role or the control suffix, which targets the main pane.
    public static func parseIdentity(_ identity: String) -> (windowID: UUID, sessionID: UUID, pane: PaneRole)? {
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let windowID = UUID(uuidString: String(parts[0])),
              let sessionID = UUID(uuidString: String(parts[1])),
              let pane = parts[2] == controlSuffix ? .main : PaneRole(rawValue: String(parts[2]))
        else { return nil }
        return (windowID, sessionID, pane)
    }

    private static let controlSuffix = "notify"

    /// Whether a notification should be delivered (banner + badge). Suppressed only when the firing
    /// pane is currently focused AND agterm is the active app — you are already looking at it.
    public static func shouldDeliver(firingIsFocused: Bool, appActive: Bool) -> Bool {
        !(firingIsFocused && appActive)
    }
}
