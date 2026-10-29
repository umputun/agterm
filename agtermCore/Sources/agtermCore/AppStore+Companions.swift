import Foundation

/// CompanionOptions configures a new companion; a nil `cwd` opens it in the parent's focused cwd.
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

/// PrimaryPaneExit is what a primary pane's exit did to its session.
public enum PrimaryPaneExit: Equatable, Sendable {
    case closed
    case promoted
    case respawned
}

public enum CompanionRefusal: Error, Equatable, Sendable {
    case noSuchSession
    case remoteParent
}

extension AppStore {
    /// companions returns a parent's companions in sidebar order, and nothing for a companion.
    public func companions(of parentID: UUID) -> [Session] {
        guard let location = location(ofSession: parentID),
              workspaces[location.workspaceIndex].sessions[location.sessionIndex].parentID == nil else { return [] }
        let sessions = workspaces[location.workspaceIndex].sessions
        return Array(sessions[(location.sessionIndex + 1)..<Self.groupEnd(from: location.sessionIndex, in: sessions)])
    }

    public func parent(of session: Session) -> Session? {
        session.parentID.flatMap(self.session(withID:))
    }

    /// addCompanion creates a companion after the parent's last one; a companion target means its parent.
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

    /// setSessionExpanded folds or unfolds a parent's companions and saves; false for a session without any.
    @discardableResult
    public func setSessionExpanded(_ id: UUID, expanded: Bool) -> Bool {
        guard let session = session(withID: id), !companions(of: id).isEmpty else { return false }
        guard session.isExpanded != expanded else { return true }
        session.isExpanded = expanded
        scheduleTreeChanged()
        save()
        return true
    }

    /// companionsNeedingAttention lists a parent's companions that are blocked, completed or carry unseen
    /// notifications, the ones a folded parent row must still surface.
    public func companionsNeedingAttention(of parentID: UUID) -> [Session] {
        companions(of: parentID).filter {
            $0.agentIndicator.status == .blocked || $0.agentIndicator.status == .completed || $0.unseenCount > 0
        }
    }

    // a remote row is respawned by its owner on the other Mac, never here
    func respawnsOnLastPaneExit(_ session: Session) -> Bool {
        session.remoteHost == nil && !companions(of: session.id).isEmpty
    }

    // the launch payload is cleared so an exited `--command` parent never reruns it; the observed respawn
    // count is what makes the deck mount a host for the new shell
    func respawnPrimaryPane(_ session: Session) {
        if session.hudPaneIdentity == session.paneIdentity { closeHud(session.id) }
        if session.askPaneIdentity == session.paneIdentity { session.cancelPendingAsk() }
        let exited = [session.surface, session.splitSurface].compactMap { $0 }
        exited.forEach { $0.teardown() }
        session.surface = nil
        session.splitSurface = nil
        if session.searchSurface == nil || exited.contains(where: { $0 === session.searchSurface }) { session.clearSearch() }
        session.splitPaneIdentity = nil
        session.isSplit = false
        session.hasSplit = false
        session.splitFocused = false
        ZmxLeadBook.shared.forget(pane: session.paneIdentity)
        session.initialCwd = session.currentCwd ?? session.initialCwd
        session.initialCommand = nil
        session.commandWait = false
        session.foregroundCommand = nil
        session.clearPendingRestoreOverrides()
        session.oscTitle = nil
        session.teardownPaneOverlay(.left)
        if session.agentIndicator.status != .idle, session.agentIndicator.statusPane != .scratch {
            setAgentIndicator(AgentIndicator(), forSession: session.id)
        }
        session.primaryRespawns &+= 1
        scheduleTreeChanged()
        save()
    }

    static func groupEnd(from index: Int, in sessions: [Session]) -> Int {
        var end = index + 1
        while end < sessions.count, sessions[end].parentID != nil { end += 1 }
        return end
    }

    // a slot in front of a companion moves past the rest of its group
    static func topLevelInsertionIndex(_ index: Int, in sessions: [Session]) -> Int {
        var slot = max(0, min(index, sessions.count))
        while slot < sessions.count, sessions[slot].parentID != nil { slot += 1 }
        return slot
    }

    func insertionIndex(for session: Session, near index: Int, in sessions: [Session]) -> Int {
        guard let parentID = session.parentID, let parent = sessions.firstIndex(where: { $0.id == parentID }) else {
            return Self.topLevelInsertionIndex(index, in: sessions)
        }
        return min(max(index, parent + 1), Self.groupEnd(from: parent, in: sessions))
    }

    // a link naming no top-level session in the list, which only a hand-edited snapshot produces, is dropped
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
