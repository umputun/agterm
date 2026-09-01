import Foundation

/// One open window's part of the launch spawn order: its selected session and its sessions in model order.
struct LaunchSpawnWindow {
    let selectedSessionID: UUID?
    let sessions: [Session]
}

/// The expected spawn order of a launch restore and the keys exempt from pacing, taken from the model
/// before any window mounts. Each open window's selected session's on-screen panes come first and form
/// the burst; the rest follow window by window, session by session, primary before shown split. A hidden
/// split, a session that was not restored, and every runtime surface are never expected, so a pane that
/// replays nothing has to leave the queue itself.
public struct LaunchSpawnPlan: Equatable, Sendable {
    public let order: [UUID]
    public let burst: Set<UUID>

    @MainActor
    static func make(windows: [LaunchSpawnWindow]) -> LaunchSpawnPlan {
        var burst: [UUID] = []
        var rest: [UUID] = []
        for window in windows {
            for session in window.sessions where session.wasRestored {
                let keys = panes(of: session)
                if session.id == window.selectedSessionID { burst += keys } else { rest += keys }
            }
        }
        return LaunchSpawnPlan(order: burst + rest, burst: Set(burst))
    }

    @MainActor
    private static func panes(of session: Session) -> [UUID] {
        // `isSplit`, not `hasSplit`: a hidden split has an identity but no right host to request or discard,
        // and an expected key nobody claims stalls the queue at its head.
        guard session.isSplit, let split = session.splitPaneIdentity else { return [session.paneIdentity] }
        return [session.paneIdentity, split]
    }
}

public extension WindowLibrary {
    /// The plan for this launch over every open window, in `windows` order.
    func launchSpawnPlan() -> LaunchSpawnPlan {
        LaunchSpawnPlan.make(windows: windows.compactMap { window in
            guard let store = store(for: window.id) else { return nil }
            return LaunchSpawnWindow(selectedSessionID: store.selectedSessionID,
                                     sessions: store.workspaces.flatMap(\.sessions))
        })
    }
}
