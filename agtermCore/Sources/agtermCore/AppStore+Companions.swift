import Foundation

/// CompanionOptions configures a new companion; a nil `cwd` opens it in the parent's focused cwd.
public struct CompanionOptions: Equatable, Sendable {
    public var cwd: String?
    public var command: String?
    public var name: String?
    public var wait: Bool
    public var select: Bool
    public var tint: SidebarTint?

    public init(cwd: String? = nil, command: String? = nil, name: String? = nil, wait: Bool = false, select: Bool = true,
                tint: SidebarTint? = nil) {
        self.tint = tint
        self.cwd = cwd
        self.command = command
        self.name = name
        self.wait = wait
        self.select = select
    }
}

/// SessionContent is what a session shows: a terminal, or an HTML page with no shell under it (a page companion).
public enum SessionContent: Equatable, Sendable {
    case terminal
    case page
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
    case pageNotOpened(HtmlOverlayOpenFailure)
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
        companionSlot(for: targetID, cwd: options.cwd).flatMap { slot in
            addSession(toWorkspace: slot.workspace, cwd: slot.cwd, command: options.command, name: options.name,
                       wait: options.wait, at: slot.index, select: options.select, tint: options.tint,
                       parentID: slot.parent).map(Result.success) ?? .failure(.noSuchSession)
        }
    }

    /// addPageCompanion creates a page companion showing `overlay` full size, with no shell under it; a page the
    /// slot refuses removes the row again.
    @discardableResult
    public func addPageCompanion(to targetID: UUID, overlay: HtmlOverlay, name: String? = nil, select: Bool = true,
                                 backgroundColor: String? = nil) -> Result<Session, CompanionRefusal> {
        companionSlot(for: targetID, cwd: nil).flatMap { slot in
            guard let page = addSession(toWorkspace: slot.workspace, cwd: slot.cwd, name: name, at: slot.index,
                                        select: select, parentID: slot.parent, content: .page) else {
                return .failure(.noSuchSession)
            }
            if let failure = openHtmlOverlay(page.id, pane: nil, overlay: overlay, sizePercent: nil,
                                             backgroundColor: backgroundColor) {
                closeSession(page.id)
                return .failure(.pageNotOpened(failure))
            }
            return .success(page)
        }
    }

    /// duplicateAsCompanion creates a companion copying a layout: `left` as its primary pane and, with `right`, a
    /// shown split on `axis` at `ratio`. A program plan becomes that pane's creation command, so the copy runs it
    /// like a `--command` session, with the source's session and pane ids in its arguments replaced by the copy's.
    @discardableResult
    public func duplicateAsCompanion(of sourceID: UUID, left: DuplicateReplay.Plan, right: DuplicateReplay.Plan?,
                                     axis: SplitAxis = .leftRight, ratio: Double? = nil,
                                     select: Bool = true) -> Result<Session, CompanionRefusal> {
        companionSlot(for: sourceID, cwd: left.workingDirectory).flatMap { slot in
            guard let source = session(withID: sourceID),
                  let copy = addSession(toWorkspace: slot.workspace, cwd: slot.cwd, at: slot.index,
                                        select: select, parentID: slot.parent) else {
                return .failure(.noSuchSession)
            }
            if let right {
                copy.initialSplitCwd = right.workingDirectory
                setSplitVisibility(copy.id, shown: true, axis: axis)
                copy.splitFocused = false
                if let ratio { applySplitRatio(ratio, forSession: copy.id) }
            }
            // the copy's pane ids exist only now; its surfaces spawn later, when the view realizes them
            let ids = identityRebinding(from: source, to: copy)
            copy.initialCommand = left.rebinding(ids).command
            copy.splitInitialCommand = right?.rebinding(ids).command
            save()
            return .success(copy)
        }
    }

    /// identityRebinding maps each id of `source` an argument may carry, including a pane's zmx daemon name, to
    /// the matching id of `copy`.
    private func identityRebinding(from source: Session, to copy: Session) -> [String: String] {
        var ids = [source.id.uuidString: copy.id.uuidString]
        var panes = [(source.paneIdentity, copy.paneIdentity)]
        if let from = source.splitPaneIdentity, let to = copy.splitPaneIdentity { panes.append((from, to)) }
        for (from, to) in panes {
            ids[from.uuidString] = to.uuidString
            ids[ZmxSupport.daemonName(for: from)] = ZmxSupport.daemonName(for: to)
        }
        return ids
    }

    private struct CompanionSlot {
        let workspace: UUID
        let index: Int
        let parent: UUID
        let cwd: String
    }

    private func companionSlot(for targetID: UUID, cwd: String?) -> Result<CompanionSlot, CompanionRefusal> {
        guard let target = session(withID: targetID) else { return .failure(.noSuchSession) }
        let parent = parent(of: target) ?? target
        guard let location = location(ofSession: parent.id) else { return .failure(.noSuchSession) }
        guard parent.remoteHost == nil else { return .failure(.remoteParent) }
        let workspace = workspaces[location.workspaceIndex]
        let cwd = cwd ?? parent.localWorkingDirectory(
            reported: parent.focusedCwd, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        return .success(CompanionSlot(workspace: workspace.id, index: Self.groupEnd(from: location.sessionIndex, in: workspace.sessions),
                                      parent: parent.id, cwd: cwd))
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

    /// respawnMinimumUptime is how long a respawned shell must run before its exit respawns it again: one exiting
    /// sooner (a broken shell or profile, a failing Live attach) would otherwise respawn forever.
    static let respawnMinimumUptime: TimeInterval = 2

    // a remote row is respawned by its owner on the other Mac, never here
    func respawnsOnLastPaneExit(_ session: Session, now: Date) -> Bool {
        guard session.remoteHost == nil, !companions(of: session.id).isEmpty else { return false }
        return session.lastRespawnAt.map { now.timeIntervalSince($0) >= Self.respawnMinimumUptime } ?? true
    }

    // the launch payload is cleared so an exited `--command` parent never reruns it; the observed respawn
    // count is what makes the deck mount a host for the new shell
    func respawnPrimaryPane(_ session: Session, now: Date) {
        session.lastRespawnAt = now
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
