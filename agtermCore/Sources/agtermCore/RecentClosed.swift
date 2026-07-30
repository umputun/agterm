import Foundation

public enum RecentClosedKind: String, Codable, Sendable {
    case session
    case workspace
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

    public init(workspaceID: UUID, workspaceName: String, workspaceIndex: Int, sessionIndex: Int,
                snapshot: SessionSnapshot) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.workspaceIndex = workspaceIndex
        self.sessionIndex = sessionIndex
        self.snapshot = snapshot
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

public struct RecentClosedState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var items: [RecentClosedItem]

    public init(version: Int = RecentClosedState.currentVersion, items: [RecentClosedItem] = []) {
        self.version = version
        self.items = items
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
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let state = try? JSONDecoder().decode(RecentClosedState.self, from: data) else { return [] }
        guard state.version == RecentClosedState.currentVersion else { return [] }
        return Array(state.items.prefix(limit))
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
        save(Array(items.prefix(limit)))
    }

    public func remove(_ id: UUID) {
        save(load().filter { $0.id != id })
    }

    public func clear() {
        save([])
    }

    private func save(_ items: [RecentClosedItem]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(RecentClosedState(items: items)).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("agterm: save recent closed failed: %@", String(describing: error))
        }
    }
}
