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
    /// host is the origin of a `remote` entry, a row attached here from another host; absent for this host's own.
    public let host: String?

    public init(id: String, kind: String, title: String, subtitle: String?, closedAt: Double,
                workspaceID: String, sessionIDs: [String], host: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.closedAt = closedAt
        self.workspaceID = workspaceID
        self.sessionIDs = sessionIDs
        self.host = host
    }

    /// remoteKind is the kind of an entry for a row attached from another host, whose session ids are the origin's.
    public static let remoteKind = "remote"

    public init(_ item: RemoteRecentClosedItem) {
        self.init(id: item.id.uuidString, kind: Self.remoteKind, title: item.name, subtitle: item.host,
                  closedAt: item.closedAt.timeIntervalSince1970, workspaceID: item.placement.workspaceID.uuidString,
                  sessionIDs: [item.originSessionID], host: item.host)
    }

    /// merged lists this host's entries and its attached rows' entries together, newest first.
    public static func merged(_ items: [RecentClosedItem], remote: [RemoteRecentClosedItem]) -> [ControlRecentItem] {
        guard !remote.isEmpty else { return items.map(ControlRecentItem.init) }
        return (items.map(ControlRecentItem.init) + remote.map(ControlRecentItem.init)).sorted { $0.closedAt > $1.closedAt }
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
    /// restored is every row the open brought into the window, a closed parent reopened first included; only a Mac
    /// serving its window to another Mac reports it.
    public let restored: [String]?

    public init(item: ControlRecentItem, window: String, complete: Bool, restored: [String]? = nil) {
        self.item = item
        self.window = window
        self.complete = complete
        self.restored = restored
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

/// RecentClosedChoice is the entry a `recent.open` target names: this host's own or an attached row's.
public enum RecentClosedChoice: Equatable, Sendable {
    case local(UUID)
    case remote(UUID)
}

extension RecentClosedTarget {
    /// resolve over both lists: the newest of either when `target` is nil, else the one id that matches.
    public static func resolve(_ target: String?, in items: [RecentClosedItem],
                               remote: [RemoteRecentClosedItem]) -> Result<RecentClosedChoice, RecentClosedTargetError> {
        guard !remote.isEmpty else { return resolve(target, in: items).map(RecentClosedChoice.local) }
        guard let target else {
            if let local = items.first, local.closedAt >= remote[0].closedAt { return .success(.local(local.id)) }
            return .success(.remote(remote[0].id))
        }
        let resolution = ControlResolve.resolve(target, candidates: items.map(\.id) + remote.map(\.id), active: nil)
        guard case .resolved(let id) = resolution else {
            return .failure(RecentClosedTargetError(
                ControlResolve.errorMessage(noun: "recent item", target: target, resolution: resolution)))
        }
        return .success(remote.contains { $0.id == id } ? .remote(id) : .local(id))
    }
}

/// A `RecentClosedTarget` refusal, carrying the wire error text.
public struct RecentClosedTargetError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}
