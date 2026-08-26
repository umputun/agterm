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

    /// Parses an `identity(windowID:sessionID:pane:)` string back into its parts, or nil if malformed. The
    /// role is the suffix after the last colon, preceded by the two colon-free UUIDs, window id first.
    public static func parseIdentity(_ identity: String) -> (windowID: UUID, sessionID: UUID, pane: PaneRole)? {
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let windowID = UUID(uuidString: String(parts[0])),
              let sessionID = UUID(uuidString: String(parts[1])),
              let pane = PaneRole(rawValue: String(parts[2]))
        else { return nil }
        return (windowID, sessionID, pane)
    }

    /// Whether a banner's identity names a window that no longer hosts its session, so a click on it would
    /// reopen the window the session left. `currentWindowID` is where that session lives now; nil means the
    /// caller cannot tell (a plain window close), which keeps the banner and its reopen click intact.
    public static func isStale(identity: String, currentWindowID: UUID?) -> Bool {
        guard let target = parseIdentity(identity), let currentWindowID else { return false }
        return currentWindowID != target.windowID
    }

    /// A delivered banner as a sweep sees it: its identity, when the OS delivered it, and when that identity
    /// was last submitted, nil for one this process never posted (an earlier launch).
    public struct DeliveredBanner: Sendable {
        public let identity: String
        public let deliveredAt: Date
        public let lastPostedAt: Date?

        public init(identity: String, deliveredAt: Date, lastPostedAt: Date?) {
            self.identity = identity
            self.deliveredAt = deliveredAt
            self.lastPostedAt = lastPostedAt
        }

        /// The later of delivery and last submission: when this banner last became something a sweep could
        /// see, and what `cutoff` is judged against.
        var touchedAt: Date { max(deliveredAt, lastPostedAt ?? .distantPast) }
    }

    /// Whether a delivered banner is one this sweep should remove: it must belong to `sessionID`, and have
    /// been neither delivered nor re-posted after `cutoff`, the moment the sweep started. The delivered set
    /// is queried asynchronously and an identity is reusable, so what the query returns can have arrived —
    /// or since been replaced by a newer banner reusing its identifier — after the sweep started, and
    /// neither is this sweep's to take. A nil `staleRelativeTo` takes every one of the session's banners
    /// (a focus clear); otherwise it spares the ones that window still owns.
    public static func shouldSweep(_ banner: DeliveredBanner, sessionID: UUID, staleRelativeTo windowID: UUID?,
                                   cutoff: Date) -> Bool {
        guard let target = parseIdentity(banner.identity), target.sessionID == sessionID else { return false }
        guard banner.touchedAt <= cutoff else { return false }
        guard let windowID else { return true }
        return windowID != target.windowID
    }

    /// The move records a sweep leaves behind. A record exists only to retarget a banner of its own
    /// session, so one whose session has neither a delivered banner nor unsettled work — closed since its
    /// move, most often — can never be consulted again. `unsettled` names the sessions with a banner
    /// submission or a concurrent sweep still outstanding, the sweeping session among them: no snapshot
    /// shows their banners yet an `add` completion or a click can still ask where they live.
    public static func retainedMoveRecords(_ records: [UUID: UUID], delivered: [String],
                                           unsettled: Set<UUID>) -> [UUID: UUID] {
        var live = unsettled
        for identity in delivered {
            if let target = parseIdentity(identity) { live.insert(target.sessionID) }
        }
        return records.filter { live.contains($0.key) }
    }

    /// Whether a notification should be delivered (banner + badge). Suppressed only when the firing
    /// pane is currently focused AND agterm is the active app — you are already looking at it.
    public static func shouldDeliver(firingIsFocused: Bool, appActive: Bool) -> Bool {
        !(firingIsFocused && appActive)
    }
}
