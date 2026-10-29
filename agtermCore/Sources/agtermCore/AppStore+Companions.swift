import Foundation

/// What a new companion starts with. `cwd` nil opens it in the parent's focused cwd, as Duplicate does.
public struct CompanionOptions: Equatable, Sendable {
    public var cwd: String?
    public var command: String?
    public var name: String?
    public var wait: Bool
    public var select: Bool

    public init(cwd: String? = nil, command: String? = nil, name: String? = nil, wait: Bool = false, select: Bool = true) {
        self.cwd = cwd
        self.command = command
        self.name = name
        self.wait = wait
        self.select = select
    }
}

/// Why a companion could not be created.
public enum CompanionRefusal: Error, Equatable, Sendable {
    case noSuchSession
    case remoteParent
}

extension AppStore {
    /// The companions of `parentID`, in sidebar order; empty for a session that has none.
    public func companions(of parentID: UUID) -> [Session] {
        guard let location = location(ofSession: parentID) else { return [] }
        let sessions = workspaces[location.workspaceIndex].sessions
        return Array(sessions[(location.sessionIndex + 1)..<Self.groupEnd(from: location.sessionIndex, in: sessions)])
    }

    /// The parent of a companion, nil for a top-level session.
    public func parent(of session: Session) -> Session? {
        session.parentID.flatMap(self.session(withID:))
    }

    /// Creates a companion of `targetID`, or of its parent when the target is itself a companion, placed after
    /// the parent's last companion. A remote parent is refused until remote companions exist.
    @discardableResult
    public func addCompanion(to targetID: UUID, options: CompanionOptions = CompanionOptions()) -> Result<Session, CompanionRefusal> {
        guard let target = session(withID: targetID) else { return .failure(.noSuchSession) }
        let parent = parent(of: target) ?? target
        guard let location = location(ofSession: parent.id) else { return .failure(.noSuchSession) }
        guard parent.remoteHost == nil else { return .failure(.remoteParent) }
        let workspace = workspaces[location.workspaceIndex]
        let cwd = options.cwd ?? parent.localWorkingDirectory(
            reported: parent.focusedCwd, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        let end = Self.groupEnd(from: location.sessionIndex, in: workspace.sessions)
        guard let companion = addSession(toWorkspace: workspace.id, cwd: cwd, command: options.command, name: options.name,
                                         wait: options.wait, at: end, select: options.select, parentID: parent.id) else {
            return .failure(.noSuchSession)
        }
        return .success(companion)
    }

    /// The exclusive end of the group whose parent sits at `index`: one past its last companion.
    static func groupEnd(from index: Int, in sessions: [Session]) -> Int {
        var end = index + 1
        while end < sessions.count, sessions[end].parentID != nil { end += 1 }
        return end
    }

    /// A top-level insertion slot that never lands inside a group: a slot in front of a companion moves past the
    /// rest of that companion's group.
    static func topLevelInsertionIndex(_ index: Int, in sessions: [Session]) -> Int {
        var slot = max(0, min(index, sessions.count))
        while slot < sessions.count, sessions[slot].parentID != nil { slot += 1 }
        return slot
    }

    /// The slot for reinserting `session` near `index`: inside its parent's group when that parent is present,
    /// otherwise a top-level slot.
    func insertionIndex(for session: Session, near index: Int, in sessions: [Session]) -> Int {
        guard let parentID = session.parentID, let parent = sessions.firstIndex(where: { $0.id == parentID }) else {
            return Self.topLevelInsertionIndex(index, in: sessions)
        }
        return min(max(index, parent + 1), Self.groupEnd(from: parent, in: sessions))
    }

    /// Puts each companion right after its parent, keeping relative order. A link that names no top-level
    /// session in this list (a missing parent, or a parent that is itself a companion) is dropped, which only
    /// a corrupt or hand-edited snapshot produces.
    static func regroupedCompanions(_ sessions: [Session]) -> [Session] {
        let parents = Set(sessions.filter { $0.parentID == nil }.map(\.id))
        for session in sessions where session.parentID.map({ !parents.contains($0) }) == true {
            session.parentID = nil
        }
        let companions = sessions.compactMap { session in session.parentID.map { (parent: $0, session: session) } }
        let byParent = Dictionary(grouping: companions, by: \.parent).mapValues { $0.map(\.session) }
        return sessions.filter { $0.parentID == nil }.flatMap { [$0] + (byParent[$0.id] ?? []) }
    }
}
