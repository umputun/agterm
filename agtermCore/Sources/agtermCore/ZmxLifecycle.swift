import Foundation

public struct ZmxSessionRecord: Equatable, Sendable {
    public let name: String
    public let clients: Int?
    public let leaderPID: Int32?

    public init(name: String, clients: Int?) {
        self.init(name: name, clients: clients, leaderPID: nil)
    }

    public init(name: String, clients: Int?, leaderPID: Int32?) {
        self.name = name
        self.clients = clients
        self.leaderPID = leaderPID
    }
}

public enum ZmxListParser {
    public enum ParseError: Error, Equatable {
        case missingName
        case missingClients(String)
        case invalidClients(String)
        case invalidLeaderPID(String)
    }

    public static func parse(_ output: String) throws -> [ZmxSessionRecord] {
        try output.split(whereSeparator: \.isNewline).map { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("→ ") { line.removeFirst(2) }
            var name: String?
            var clients: Int?
            var leaderPID: Int32?
            var hasError = false
            for field in line.split(separator: "\t", omittingEmptySubsequences: false) {
                if field.hasPrefix("name=") {
                    name = String(field.dropFirst("name=".count))
                } else if field.hasPrefix("clients=") {
                    let raw = String(field.dropFirst("clients=".count))
                    guard let value = Int(raw), value >= 0 else { throw ParseError.invalidClients(raw) }
                    clients = value
                } else if field.hasPrefix("pid=") {
                    let raw = String(field.dropFirst("pid=".count))
                    guard let value = Int32(raw), value > 0 else { throw ParseError.invalidLeaderPID(raw) }
                    leaderPID = value
                } else if field.hasPrefix("err=") {
                    hasError = true
                }
            }
            guard let name, !name.isEmpty else { throw ParseError.missingName }
            guard clients != nil || hasError else { throw ParseError.missingClients(name) }
            return ZmxSessionRecord(name: name, clients: clients, leaderPID: leaderPID)
        }
    }
}

public enum ZmxLeaderMap {
    public static func leaders(in sessions: [ZmxSessionRecord]) -> [String: Int32] {
        Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            guard ZmxSupport.isDaemonName(session.name), let leaderPID = session.leaderPID else { return nil }
            return (session.name, leaderPID)
        })
    }
}

public struct ZmxRefreshGate: Sendable {
    public static let reconcileInterval: TimeInterval = 30

    private var invalidated = true
    private var lastRefreshAt: Date?

    public init() {}

    public mutating func noteLifecycleChange() {
        invalidated = true
    }

    public mutating func shouldRefresh(now: Date) -> Bool {
        let expired = lastRefreshAt.map { now.timeIntervalSince($0) >= Self.reconcileInterval } ?? true
        guard invalidated || expired else { return false }
        invalidated = false
        lastRefreshAt = now
        return true
    }
}

public enum ZmxForegroundRefreshPolicy {
    @MainActor public static func hasWrappedPane(in sessions: [Session]) -> Bool {
        sessions.contains { session in
            session.surface?.backedByZmx == true || session.splitSurface?.backedByZmx == true
        }
    }
}

public enum ZmxReapPolicy {
    /// Nil means a requested-live inventory was incomplete and no reap is safe. A deliberate non-live
    /// request claims no daemon and removes every zero-client daemon this app could have emitted.
    ///
    /// `isDaemonName` rather than the prefix alone, matching prune and kill: the namespace is a shared
    /// /tmp directory and this is the one path that destroys without the user asking.
    public static func namesToKill(sessions: [ZmxSessionRecord], requestedMode: RestoreMode,
                                   knownNames: Set<String>?) -> [String]? {
        let liveRequested = requestedMode == .live
        if liveRequested, knownNames == nil { return nil }
        let claimed = knownNames ?? []
        return sessions.compactMap { session in
            guard ZmxSupport.isDaemonName(session.name), session.clients == 0 else { return nil }
            guard !liveRequested || !claimed.contains(session.name) else { return nil }
            return session.name
        }
    }
}

public enum PaneIdentityInventory {
    public struct Upgrade: Sendable {
        public let identities: Set<UUID>
        public let changed: Bool
    }

    public static func upgrade(_ snapshot: inout Snapshot) -> Upgrade {
        var identities: Set<UUID> = []
        var changed = false
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                var session = snapshot.workspaces[workspaceIndex].sessions[sessionIndex]
                if session.paneIdentity == nil {
                    session.paneIdentity = UUID()
                    changed = true
                }
                if let paneIdentity = session.paneIdentity { identities.insert(paneIdentity) }
                let hasSplit = (session.isSplit ?? false) || (session.hasSplit ?? false)
                if hasSplit {
                    if session.splitPaneIdentity == nil {
                        session.splitPaneIdentity = UUID()
                        changed = true
                    }
                    if let splitPaneIdentity = session.splitPaneIdentity { identities.insert(splitPaneIdentity) }
                }
                snapshot.workspaces[workspaceIndex].sessions[sessionIndex] = session
            }
        }
        return Upgrade(identities: identities, changed: changed)
    }

    @MainActor public static func identities(in sessions: [Session]) -> [UUID] {
        sessions.flatMap { session in
            [session.paneIdentity] + [session.splitPaneIdentity].compactMap { $0 }
        }
    }
}
