import Foundation

/// One Recent Closed entry as `recent.list` reports it: a summary, never the snapshot it restores from.
/// `workspaceID` is the parent workspace for a session entry and the workspace itself for a workspace
/// entry; `sessionIDs` are the sessions a reopen brings back, a parent's companions after it. `closedAt` is
/// Unix seconds.
public struct ControlRecentItem: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let title: String
    public let subtitle: String?
    public let closedAt: Double
    public let workspaceID: String
    public let sessionIDs: [String]

    public init(id: String, kind: String, title: String, subtitle: String?, closedAt: Double,
                workspaceID: String, sessionIDs: [String]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.closedAt = closedAt
        self.workspaceID = workspaceID
        self.sessionIDs = sessionIDs
    }

    public init(_ item: RecentClosedItem) {
        let workspaceID: UUID?
        let sessionIDs: [UUID]
        switch item.kind {
        case .session:
            workspaceID = item.session?.workspaceID
            sessionIDs = item.session.map { [$0.snapshot.id] + ($0.companions ?? []).map(\.id) } ?? []
        case .workspace:
            workspaceID = item.workspace?.snapshot.id
            sessionIDs = item.workspace?.snapshot.sessions.map(\.id) ?? []
        }
        self.init(id: item.id.uuidString, kind: item.kind.rawValue, title: item.title, subtitle: item.subtitle,
                  closedAt: item.closedAt.timeIntervalSince1970, workspaceID: workspaceID?.uuidString ?? "",
                  sessionIDs: sessionIDs.map(\.uuidString))
    }
}

/// What `recent.open` did. `window` is where the entry was restored, which can differ from the requested
/// window when another window already holds its session or workspace. `complete` is false when the entry
/// is still in the list afterwards, so a later open can finish the restore.
public struct ControlRecentOpen: Codable, Sendable, Equatable {
    public let item: ControlRecentItem
    public let window: String
    public let complete: Bool

    public init(item: ControlRecentItem, window: String, complete: Bool) {
        self.item = item
        self.window = window
        self.complete = complete
    }
}

/// Host-free resolution of a `recent.open` target against the current entries.
public enum RecentClosedTarget {
    public static let emptyError = "no recently closed items"

    /// The entry to open: the newest when `target` is nil, else the one whose id matches exactly or by
    /// unique prefix. `active` names nothing here, since the list has no current entry.
    public static func resolve(_ target: String?, in items: [RecentClosedItem]) -> Result<UUID, RecentClosedTargetError> {
        guard let first = items.first else { return .failure(RecentClosedTargetError(emptyError)) }
        guard let target else { return .success(first.id) }
        let resolution = ControlResolve.resolve(target, candidates: items.map(\.id), active: nil)
        guard case .resolved(let id) = resolution else {
            return .failure(RecentClosedTargetError(
                ControlResolve.errorMessage(noun: "recent item", target: target, resolution: resolution)))
        }
        return .success(id)
    }
}

/// A `RecentClosedTarget` refusal, carrying the wire error text.
public struct RecentClosedTargetError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}
