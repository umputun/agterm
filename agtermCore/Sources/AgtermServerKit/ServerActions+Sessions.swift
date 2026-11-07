import Foundation
import agtermCore

/// The session commands agterm-server serves. They change the catalog as a Mac window's commands change its
/// store and start or end the daemons behind it; nothing here selects or focuses, since the Macs showing the
/// catalog own their own selection.
extension ServerActions {
    public func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse {
        createSession(options, tint: nil)
    }

    public func createSession(_ options: ControlSessionCreateOptions, tint: SidebarTint?) -> ControlResponse {
        if let refusal = windowRefusal(options.window) { return refusal }
        guard options.wait != true else { return ControlResponse(ok: false, error: "session.new --wait is not available on agterm-server") }
        let destination: (workspace: UUID, index: Int?)
        switch sessionDestination(options) {
        case .success(let resolved): destination = resolved
        case .failure(let refusal): return refusal.response
        }
        let cwd = options.cwd ?? panes.baseEnvironment["HOME"] ?? "/"
        guard let session = store.addSession(toWorkspace: destination.workspace, cwd: cwd, command: options.command,
                                             name: options.name, at: destination.index, select: false, tint: tint) else {
            return ControlResponse(ok: false, error: "could not create session")
        }
        if let refusal = panes.start(.init(identity: session.paneIdentity, session: session, workspace: destination.workspace,
                                           pane: .left, command: options.command, directory: cwd)) {
            store.closeSession(session.id, alreadyFinalized: session.paneIdentity)
            return ControlResponse(ok: false, error: refusal)
        }
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
    }

    public func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse {
        withSession(target, window: window) { session in
            store.renameSession(session.id, to: name)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func closeSession(_ target: String?, window: String?) -> ControlResponse {
        withSession(target, window: window) { session in
            let closing = [session.id] + store.companions(of: session.id).map(\.id)
            store.closeSession(session.id)
            let closed = closing.filter { store.session(withID: $0) == nil }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString,
                                                                   affected: closing.count > 1 ? closing.count : nil,
                                                                   closed: closed.map(\.uuidString)))
        }
    }

    public func closeSessions(_ targets: [String], window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        let ids: [UUID]
        switch resolveSessionIDs(targets) {
        case .failure(let refusal): return refusal.response
        case .success(let resolved): ids = resolved
        }
        guard ids.count > 1 else {
            guard let id = ids.first else { return ControlResponse(ok: false, error: "session.close requires at least one --target") }
            return closeSession(id.uuidString, window: window)
        }
        let named = Set(ids)
        let roots = ids.filter { store.session(withID: $0)?.parentID.map(named.contains) != true }
        let closing = roots.flatMap { [$0] + store.companions(of: $0).map(\.id) }
        for id in roots where store.session(withID: id) != nil { store.closeSession(id) }
        let closed = closing.filter { store.session(withID: $0) == nil }
        return ControlResponse(ok: true, result: ControlResult(affected: closed.count, closed: closed.map(\.uuidString)))
    }

    public func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        splitSession(target, window: window, mode: mode, axis: nil)
    }

    /// splitSession on `on` or a toggle that shows the split starts the right pane's daemon when the session has
    /// none yet; `off` hides the pane and keeps its daemon, as on the Mac.
    public func splitSession(_ target: String?, window: String?, mode: String?, axis: SplitAxis?) -> ControlResponse {
        withSession(target, window: window) { session in
            guard !session.ended else { return ControlResponse(ok: false, error: "session has ended") }
            guard let parsed = ControlToggleMode.parse(mode) else {
                return ControlResponse(ok: false, error: "invalid split mode: \(mode ?? "toggle")")
            }
            switch parsed {
            case .on: store.setSplitVisibility(session.id, shown: true, axis: axis)
            case .off: store.setSplitVisibility(session.id, shown: false)
            case .toggle: store.toggleSplit(session.id, axis: axis)
            }
            if let split = session.splitPaneIdentity, !session.daemonBackedPanes.contains(split) {
                let workspace = store.sessionLocation(ofSession: session.id)?.workspace
                if let refusal = panes.start(.init(identity: split, session: session, workspace: workspace, pane: .right,
                                                   directory: session.cwd(for: .left))) {
                    store.closeSplit(session.id, alreadyFinalized: split)
                    return ControlResponse(ok: false, error: refusal)
                }
            }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func closeSessionSplit(_ target: String?, window: String?) -> ControlResponse {
        withSession(target, window: window) { session in
            if session.hasSplit { store.closeSplit(session.id) }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func swapSessionPanes(_ target: String?, window: String?) async -> ControlResponse {
        withSession(target, window: window) { session in
            switch store.swapPanes(session.id) {
            case nil: ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
            case .noSplit: ControlResponse(ok: false, error: "session has no split")
            case .noSession: ControlResponse(ok: false, error: "no such session")
            case .slotNotRealized, .roleNotMutable: ControlResponse(ok: false, error: "session not realized")
            }
        }
    }

    public func createCompanion(_ target: String?, options: CompanionOptions, window: String?) async -> ControlResponse {
        withSession(target, window: window) { parent in
            guard !parent.ended else { return ControlResponse(ok: false, error: "session has ended") }
            guard options.wait != true else {
                return ControlResponse(ok: false, error: "session.companion.new --wait is not available on agterm-server")
            }
            var options = options
            options.select = false
            guard case .success(let companion) = store.addCompanion(to: parent.id, options: options) else {
                return ControlResponse(ok: false, error: "could not create companion")
            }
            let workspace = store.sessionLocation(ofSession: companion.id)?.workspace
            if let refusal = panes.start(.init(identity: companion.paneIdentity, session: companion, workspace: workspace,
                                               pane: .left, command: options.command, directory: companion.effectiveCwd)) {
                store.closeSession(companion.id, alreadyFinalized: companion.paneIdentity)
                return ControlResponse(ok: false, error: refusal)
            }
            return ControlResponse(ok: true, result: ControlResult(id: companion.id.uuidString,
                                                                   parent: companion.parentID?.uuidString))
        }
    }

    public func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse {
        withSession(target, window: window) { session in
            let identity: UUID
            switch daemonPane(of: session, token: options.paneID, pane: options.pane) {
            case .success(let resolved): identity = resolved.identity
            case .failure(let refusal): return refusal.response
            }
            guard let screen = panes.runner.screen(panes.daemonName(for: identity), all: options.all) else {
                return ControlResponse(ok: false, error: "failed to read surface buffer")
            }
            let text = options.lines.map(screen.lastLines) ?? screen.text
            return ControlResponse(ok: true, result: ControlResult(text: text))
        }
    }

    public func typeSession(_ target: String?, window: String?, options: ControlSessionTypeOptions) async -> ControlResponse {
        withSession(target, window: window) { session in
            let resolved: (identity: UUID, pane: StatusPane)
            switch daemonPane(of: session, token: options.paneID, pane: options.pane) {
            case .success(let pane): resolved = pane
            case .failure(let refusal): return refusal.response
            }
            let name = panes.daemonName(for: resolved.identity)
            let paced = KeystrokeSegments.paced(options.text)
            let bytes = KeystrokeSegments.ptyBytes(paced.head)
            guard bytes.isEmpty || panes.runner.type(name, bytes: bytes) else {
                return ControlResponse(ok: false, error: "the pane's zmx daemon did not accept the input")
            }
            if paced.pacedReturn {
                Thread.sleep(forTimeInterval: KeystrokeSegments.submitGap)
                // a failed call does not prove the Return was dropped: the daemon queues before it answers
                guard panes.runner.type(name, bytes: [0x0D]) else {
                    return ControlResponse(ok: false, error: "text typed, but its final Return could not be confirmed; do not retype the text")
                }
            }
            var result = ControlResult(id: session.id.uuidString)
            result.pane = resolved.pane.rawValue
            return ControlResponse(ok: true, result: result)
        }
    }

    // MARK: - Resolution

    func withSession(_ target: String?, window: String?, _ body: (Session) -> ControlResponse) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        switch resolveSession(target) {
        case .success(let session): return body(session)
        case .failure(let refusal): return refusal.response
        }
    }

    /// resolveSession resolves a session id, prefix or `active` across the catalog.
    func resolveSession(_ target: String?) -> Result<Session, ActionRefusal> {
        let target = target ?? "active"
        let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
        let resolution = ControlResolve.resolve(target, candidates: candidates, active: store.selectedSessionID)
        guard case .resolved(let id) = resolution, let session = store.session(withID: id) else {
            return .refused(ControlResponse(ok: false, error: ControlResolve.errorMessage(noun: "session", target: target,
                                                                                          resolution: resolution)))
        }
        return .success(session)
    }

    /// resolveSessionIDs resolves batch targets in order, deduplicated; one unresolved target refuses the batch.
    func resolveSessionIDs(_ targets: [String]) -> Result<[UUID], ActionRefusal> {
        var ids: [UUID] = []
        for target in targets {
            switch resolveSession(target) {
            case .success(let session): if !ids.contains(session.id) { ids.append(session.id) }
            case .failure(let refusal): return .failure(refusal)
            }
        }
        return .success(ids)
    }

    /// daemonPane is the pane a `--pane`/`--pane-id` pair names, defaulting to the left one, when it has a daemon.
    private func daemonPane(of session: Session, token: String?, pane: StatusPane?) -> Result<(identity: UUID, pane: StatusPane), ActionRefusal> {
        guard case .pane(let resolved) = session.paneAddress(token: token, pane: pane) else {
            return .refused(ControlResponse(ok: false, error: "unknown pane id: \(token ?? "")"))
        }
        let role = resolved ?? .left
        if role == .scratch {
            guard let scratch = session.scratchDaemon else { return .refused(ControlResponse(ok: false, error: "session not realized")) }
            return .success((scratch.identity, role))
        }
        guard let identity = session.paneIdentity(for: role), session.daemonBackedPanes.contains(identity) else {
            return .refused(ControlResponse(ok: false, error: "session not realized"))
        }
        return .success((identity, role))
    }

    private func sessionDestination(_ options: ControlSessionCreateOptions) -> Result<(workspace: UUID, index: Int?), ActionRefusal> {
        if let anchor = options.after ?? options.before {
            switch resolveSession(anchor) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let session):
                guard let location = store.sessionLocation(ofSession: session.id) else {
                    return .refused(ControlResponse(ok: false, error: "no such session"))
                }
                return .success((location.workspace, options.before != nil ? location.index : location.index + 1))
            }
        }
        if let name = options.workspaceName {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .refused(ControlResponse(ok: false, error: "workspace name must not be blank"))
            }
            let workspace = options.createWorkspace == true
                ? store.ensureWorkspace(named: name, revealNewWorkspace: false) : store.workspace(named: name)
            guard let workspace else {
                return .refused(ControlResponse(ok: false, error: "no workspace named \"\(name)\" (pass --create-workspace to add it)"))
            }
            return .success((workspace.id, nil))
        }
        return resolveWorkspace(options.workspace).map { ($0, nil) }
    }
}
