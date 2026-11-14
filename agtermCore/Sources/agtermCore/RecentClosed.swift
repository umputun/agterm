import Foundation

public enum RecentClosedKind: String, Codable, Sendable {
    case session
    case workspace
}

/// What one `restoreRecentClosed` call achieved. `complete` is false when a member of the snapshot ended
/// up neither in the restoring store nor in another window that already held it, which is the case where
/// consuming the recent entry would lose that session for good.
struct RecentClosedRestore: Equatable, Sendable {
    let restored: Bool
    let complete: Bool

    static let failed = RecentClosedRestore(restored: false, complete: false)
}

/// What `WindowLibrary.reopenRecentClosedOutcome` achieved: the window the entry was restored into, and
/// whether the entry is gone from the list.
public struct RecentClosedReopen: Equatable, Sendable {
    public let window: UUID
    public let complete: Bool
}

public struct RecentClosedItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: RecentClosedKind
    public let title: String
    public let subtitle: String?
    public let closedAt: Date
    public let session: RecentClosedSession?
    public let workspace: RecentClosedWorkspace?

    public init(id: UUID = UUID(), kind: RecentClosedKind, title: String, subtitle: String?,
                closedAt: Date = Date(), session: RecentClosedSession? = nil,
                workspace: RecentClosedWorkspace? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.closedAt = closedAt
        self.session = session
        self.workspace = workspace
    }
}

public struct RecentClosedSession: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let workspaceName: String
    public let workspaceIndex: Int
    public let sessionIndex: Int
    public let snapshot: SessionSnapshot
    /// companions are reopened under the parent; optional so an older `recent-closed.json` still decodes.
    public let companions: [SessionSnapshot]?

    public init(workspaceID: UUID, workspaceName: String, workspaceIndex: Int, sessionIndex: Int,
                snapshot: SessionSnapshot, companions: [SessionSnapshot]? = nil) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.workspaceIndex = workspaceIndex
        self.sessionIndex = sessionIndex
        self.snapshot = snapshot
        self.companions = companions
    }
}

public struct RecentClosedWorkspace: Codable, Equatable, Sendable {
    public let snapshot: WorkspaceSnapshot
    public let selectedSessionID: UUID?
    /// Whether the workspace was a MEMBER of the sidebar focus set when it closed, so Reopen Closed Item can
    /// mark it again instead of appending it invisibly behind a still-applied filter. Membership ONLY — the
    /// filter FLAG is deliberately not recorded, being current window state rather than a property of the
    /// closed workspace (see `AppStore.markFocusMember`). OPTIONAL because this struct persists in
    /// `recent-closed.json`: a required key would fail the whole decode of an older file, and
    /// `RecentClosedStore.load()` turns a decode failure into an EMPTY list — the user's entire recent list.
    /// Absent (nil) reads as "not a member", the behavior of every pre-existing entry.
    public let focusMember: Bool?

    public init(snapshot: WorkspaceSnapshot, selectedSessionID: UUID?, focusMember: Bool? = nil) {
        self.snapshot = snapshot
        self.selectedSessionID = selectedSessionID
        self.focusMember = focusMember
    }
}

/// AttachedUndo is an undoable terminate of rows attached from `host`, kept so ⌘Z in their window can undo it there
/// while the host's grace lasts: the host's undo id, the host sessions it ended (parent first) and when it was asked for.
public struct AttachedUndo: Equatable, Sendable {
    public let host: String
    public let undoID: String
    public let sessions: [String]
    public let initiated: Date

    public init(host: String, undoID: String, sessions: [String], initiated: Date) {
        self.host = host
        self.undoID = undoID
        self.sessions = sessions
        self.initiated = initiated
    }
}

/// RemoteRecentClosedItem is a closed row that was attached from another host: the session stays the origin's, so the
/// entry names it there instead of carrying a snapshot.
public struct RemoteRecentClosedItem: Codable, Identifiable, Equatable, Sendable {
    public struct Placement: Codable, Equatable, Sendable {
        public let workspaceID: UUID
        public let workspaceName: String
        public let workspaceIndex: Int
        public let sessionIndex: Int
        public let parentID: UUID?

        public init(workspaceID: UUID, workspaceName: String, workspaceIndex: Int, sessionIndex: Int, parentID: UUID?) {
            self.workspaceID = workspaceID
            self.workspaceName = workspaceName
            self.workspaceIndex = workspaceIndex
            self.sessionIndex = sessionIndex
            self.parentID = parentID
        }
    }

    public let id: UUID
    public let closedAt: Date
    public let host: String
    public let originSessionID: String
    /// originRecentID is the origin's own Recent Closed entry, set when the close ended the session there; nil for a
    /// detach and for a close that ended several sessions, which the origin's list names by session id.
    public let originRecentID: String?
    public let name: String
    public let placement: Placement
    /// closeID is the workspace close that wrote the entry, so undoing that close removes it too.
    public let closeID: UUID?

    public init(id: UUID = UUID(), closedAt: Date = Date(), host: String, originSessionID: String, originRecentID: String? = nil,
                name: String, placement: Placement, closeID: UUID? = nil) {
        self.id = id
        self.closedAt = closedAt
        self.host = host
        self.originSessionID = originSessionID
        self.originRecentID = originRecentID
        self.name = name
        self.placement = placement
        self.closeID = closeID
    }

    func withOriginRecentID(_ recentID: String) -> RemoteRecentClosedItem {
        RemoteRecentClosedItem(id: id, closedAt: closedAt, host: host, originSessionID: originSessionID,
                               originRecentID: recentID, name: name, placement: placement, closeID: closeID)
    }
}

public struct RecentClosedState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var items: [RecentClosedItem]
    /// remoteItems is optional so a build that predates it decodes the file and keeps `items`.
    public var remoteItems: [RemoteRecentClosedItem]?

    public init(version: Int = RecentClosedState.currentVersion, items: [RecentClosedItem] = [],
                remoteItems: [RemoteRecentClosedItem]? = nil) {
        self.version = version
        self.items = items
        self.remoteItems = remoteItems
    }
}

public struct RecentClosedStore: Sendable {
    private let directory: URL
    private let fileName: String
    private let limit: Int

    private var fileURL: URL { directory.appendingPathComponent(fileName) }

    public init(directory: URL = PersistenceStore.defaultDirectory,
                fileName: String = "recent-closed.json",
                limit: Int = 20) {
        self.directory = directory
        self.fileName = fileName
        self.limit = max(1, limit)
    }

    public func load() -> [RecentClosedItem] {
        loadState().items
    }

    public func loadRemote() -> [RemoteRecentClosedItem] {
        loadState().remoteItems ?? []
    }

    private func loadState() -> RecentClosedState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(RecentClosedState.self, from: data),
              state.version == RecentClosedState.currentVersion else { return RecentClosedState() }
        return RecentClosedState(items: Array(state.items.prefix(limit)),
                                 remoteItems: state.remoteItems.map { Array($0.prefix(limit)) })
    }

    /// recordRemote keeps one entry per origin session: a later close of the same session replaces the earlier one.
    public func recordRemote(_ item: RemoteRecentClosedItem) {
        var remote = loadRemote()
        remote.removeAll { $0.id == item.id || ($0.host == item.host && $0.originSessionID == item.originSessionID) }
        remote.insert(item, at: 0)
        save(load(), remote: Array(remote.prefix(limit)))
    }

    /// setOriginRecentID records that the origin's entry `recentID` holds `host`'s session `sessionID`, closed here.
    public func setOriginRecentID(_ recentID: String, host: String, sessionID: String) {
        let remote = loadRemote().map {
            $0.host == host && $0.originSessionID == sessionID ? $0.withOriginRecentID(recentID) : $0
        }
        save(load(), remote: remote)
    }

    public func record(_ item: RecentClosedItem) {
        var items = load()
        items.removeAll { existing in
            if existing.id == item.id { return true }
            switch (existing.kind, item.kind) {
            case (.session, .session):
                return existing.session?.snapshot.id == item.session?.snapshot.id
            case (.workspace, .workspace):
                return existing.workspace?.snapshot.id == item.workspace?.snapshot.id
            default:
                return false
            }
        }
        items.insert(item, at: 0)
        save(Array(items.prefix(limit)), remote: loadRemote())
    }

    /// remove drops entry `id` from both lists, and every remote entry a workspace close `id` wrote.
    public func remove(_ id: UUID) {
        save(load().filter { $0.id != id }, remote: loadRemote().filter { $0.id != id && $0.closeID != id })
    }

    public func clear() {
        save([], remote: [])
    }

    private func save(_ items: [RecentClosedItem], remote: [RemoteRecentClosedItem]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let state = RecentClosedState(items: items, remoteItems: remote.isEmpty ? nil : remote)
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("agterm: save recent closed failed: %@", String(describing: error))
        }
    }
}
