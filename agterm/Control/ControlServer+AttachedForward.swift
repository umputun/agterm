import Foundation
import agtermCore

/// AttachedPlan is a request on rows attached from another host, decided on the main actor and sent to their origin
/// from a worker, so the accept thread never waits on ssh and an origin that is this Mac cannot deadlock it.
enum AttachedPlan: Sendable {
    /// attaches is the forward's own `attachesPane`, false for a restart of a pane this window does not lay out.
    case forward(AttachedForward, origin: AttachedOrigin, row: UUID, then: AttachedFollowUp, attaches: Bool)
    case terminate(TerminatePlan)
}

/// AttachedFollowUp is what the viewer does here once the origin answered ok.
enum AttachedFollowUp: Sendable, Equatable {
    case none
    /// attachAfter attaches the session the origin created right after the row.
    case attachAfter
    /// nestUnderCreated attaches the parent the origin created at the row's slot and moves the row's group under it.
    case nestUnderCreated
    /// select selects the row, as `--follow` does.
    case select
    /// moveUnder moves the row under the local `parent` at `index`, the slot the origin was not told.
    case moveUnder(parent: UUID, index: Int?)
    /// promoteHere makes the row top-level at the local placement, which the origin was not told.
    case promoteHere(CompanionPromotion)
}

/// TerminatePlan is a `session.terminate` split by where each root runs: one origin close per origin, and the local
/// rows closed here as `session.close` closes them.
struct TerminatePlan: Sendable {
    struct Group: Sendable {
        let origin: AttachedOrigin
        let sessions: [String]
    }

    let groups: [Group]
    let local: [UUID]
    let undoable: Bool
    /// window is where the terminate was asked for, whose ⌘Z undoes it; initiated orders it against local closes.
    let window: UUID?
    let initiated: Date
}

extension ControlServer {
    /// attachedRoute sends a request on a row attached from another host to its origin; nil runs it here as usual.
    func attachedRoute(_ request: ControlRequest) -> RemoteRoute? {
        if request.cmd == .sessionTerminate { return terminateRoute(request) }
        let forwarded: Set<Command> = [.sessionRestart, .zmxKill, .zmxKillPane, .sessionCompanionConvert, .sessionCompanionMove,
                                       .sessionCompanionPromote, .sessionDuplicate, .sessionSplit, .sessionSplitClose, .sessionScratch, .sessionRestore]
        // a request the command's own checks refuse goes on to the dispatcher, which answers it in its own words
        guard forwarded.contains(request.cmd), !ControlDispatcher.refusesArguments(request) else { return nil }
        // zmx.kill refuses `active` itself; resolving it here would aim the kill at whatever is in front
        if request.cmd == .zmxKill || request.cmd == .zmxKillPane,
           request.target == "active" || request.args?.window == "active" { return nil }
        guard case .success(let (store, id)) = resolver.resolveSessionTarget(request.target, window: request.args?.window),
              let row = store.session(withID: id), let origin = AttachedOrigin(row) else { return nil }
        if request.cmd == .sessionScratch, let refusal = originScratchRefusal(row, origin: origin) {
            return .refused(ControlResponse(ok: false, error: refusal))
        }
        if request.cmd == .sessionCompanionMove { return companionMoveRoute(request, row: row, origin: origin, in: store) }
        if request.cmd == .sessionCompanionPromote { return companionPromoteRoute(request, row: row, origin: origin, in: store) }
        switch attachedForward(request, row: row, origin: origin) {
        case .failure(let refusal): return .refused(ControlResponse(ok: false, error: refusal.message))
        case .success(let (forward, then)):
            let attaches = forward.attachesPane && restartedPaneIsMounted(request, row: row, origin: origin)
            return .attached(.forward(forward, origin: origin, row: id, then: then, attaches: attaches))
        }
    }

    /// companionMoveRoute checks the move here before the origin is asked, since a row attached alone can be top-level
    /// here and a companion there. A move to the row's own parent is a reorder, which stays on this Mac.
    private func companionMoveRoute(_ request: ControlRequest, row: Session, origin: AttachedOrigin, in store: AppStore) -> RemoteRoute? {
        guard let parent = request.args?.parent?.trimmingCharacters(in: .whitespaces) else { return nil }
        let resolution = ControlResolve.resolve(parent, candidates: store.workspaces.flatMap { $0.sessions.map(\.id) },
                                                active: store.selectedSessionID)
        guard case .resolved(let parentID) = resolution else {
            return .refused(ControlResponse(ok: false, error: ControlResolve.errorMessage(noun: "session", target: parent, resolution: resolution)))
        }
        if case .failure(let refusal) = store.canMoveCompanion(row.id, under: parentID) {
            return .refused(ControlResponse(ok: false, error: refusal.message))
        }
        guard row.parentID != parentID else { return nil }
        guard let parentRow = store.session(withID: parentID), let parentOrigin = AttachedOrigin(parentRow) else {
            return .refused(ControlResponse(ok: false, error: CompanionMoveRefusal.otherHost.message))
        }
        return .attached(.forward(.moveCompanion(session: origin.session, parent: parentOrigin.session), origin: origin, row: row.id,
                                  then: .moveUnder(parent: parentID, index: request.args?.index), attaches: false))
    }

    /// companionPromoteRoute asks the origin only when the row's parent shares its origin: a row nested here under a
    /// local row or another host's is a companion on this Mac alone, so it is promoted here as a local one is. A shared
    /// origin does not prove the same grouping there, which the origin's own reply settles.
    private func companionPromoteRoute(_ request: ControlRequest, row: Session, origin: AttachedOrigin, in store: AppStore) -> RemoteRoute? {
        guard let placement = ControlDispatcher.companionPromotion(request.args) else { return nil }
        let promotion: CompanionPromotion
        switch promotionTarget(placement, in: store) {
        case .failure(let response): return .refused(response)
        case .success(let resolved): promotion = resolved
        }
        if case .failure(let refusal) = store.canPromoteCompanion(row.id, to: promotion) {
            return .refused(ControlResponse(ok: false, error: refusal.message))
        }
        guard let parent = row.parentID.flatMap(store.session(withID:)), let parentOrigin = AttachedOrigin(parent),
              parentOrigin.shares(origin) else { return nil }
        return .attached(.forward(.promoteCompanion(session: origin.session), origin: origin, row: row.id, then: .promoteHere(promotion), attaches: false))
    }

    /// originScratchRefusal is why an attached row cannot show its origin's scratch: a row runs no scratch of its own.
    private func originScratchRefusal(_ row: Session, origin: AttachedOrigin) -> String? {
        // a dropped stream keeps the last layout, which no longer says the origin can show a scratch here
        guard let state = row.remotePresentation, state.connection == .connected, let layout = state.layout else {
            return "the session on \(origin.host) is not connected; the scratch did not change"
        }
        return layout.scratchShown == nil ? "the agterm on \(origin.host) is too old to show its scratch here" : nil
    }

    /// AttachedRefusal is why a request on an attached row is refused before anything is sent.
    struct AttachedRefusal: Error {
        let message: String
    }

    private func attachedForward(_ request: ControlRequest, row: Session, origin: AttachedOrigin)
        -> Result<(AttachedForward, AttachedFollowUp), AttachedRefusal> {
        let args = request.args
        let session = origin.session
        switch request.cmd {
        case .sessionRestart:
            guard remoteClients[row.id]?.originSupports(PresentationHub.restartRespawnKind) == true else {
                return .failure(AttachedRefusal(message: remoteClients[row.id]?.originSupports("layout") == true
                    ? "the agterm on \(origin.host) is too old to restart a pane from here"
                    : "the session on \(origin.host) is not connected; nothing was restarted"))
            }
            return originPane(args, of: row, origin: origin, token: .strict).map {
                (.restart(session: session, paneID: $0.token, command: args?.command), .none)
            }
        case .zmxKill, .zmxKillPane:
            // with no layout to say otherwise the local role goes, and the origin refuses a token that is not that pane
            return originPane(args, of: row, origin: origin, token: request.cmd == .zmxKillPane ? .pinned : .ignored).map {
                (.killPane(session: session, pane: originRole(of: row, pane: $0.token) ?? $0.role, paneID: $0.token), .none)
            }
        case .sessionCompanionConvert:
            return .success((.convert(session: session), .nestUnderCreated))
        case .sessionDuplicate:
            return .success((.duplicate(after: session, cwd: row.focusedCwd), .attachAfter))
        case .sessionSplit:
            return .success((.split(session: session, mode: args?.mode ?? "toggle", axis: args?.axis), .none))
        case .sessionSplitClose:
            return .success((.closeSplit(session: session), .none))
        case .sessionScratch:
            return .success((.scratch(session: session, mode: args?.mode ?? "toggle", command: args?.command),
                             args?.follow == true ? .select : .none))
        case .sessionRestore:
            return restoreForward(args, row: row, origin: origin).map { ($0, .none) }
        default:
            return .failure(AttachedRefusal(message: "\(request.cmd.rawValue) is not available on a session attached from another host"))
        }
    }

    private func restoreForward(_ args: ControlArgs?, row: Session, origin: AttachedOrigin) -> Result<AttachedForward, AttachedRefusal> {
        if origin.headless { return .failure(AttachedRefusal(message: "agterm-server keeps every pane running")) }
        let pin: ControlRestoreOverride
        switch args?.mode {
        case "set": pin = .pin(args?.command ?? "")
        case "none": pin = .pinNone
        case "clear": pin = .unpin
        default: return .failure(AttachedRefusal(message: "invalid restore mode: \(args?.mode ?? "") (set|none|clear)"))
        }
        var pane = args
        if pane?.pane == nil, pane?.paneID == nil { pane = ControlArgs(pane: "left") }
        return originPane(pane, of: row, origin: origin, token: .fallback).map { .restore(session: origin.session, paneID: $0.token, pin: pin) }
    }

    /// PaneToken is how a command treats `--pane-id` beside `--pane`, as its local form does.
    private enum PaneToken {
        /// strict refuses an unknown token even beside a role (`session.restart`).
        case strict
        /// fallback takes the role when the token is unknown (`session.restore`).
        case fallback
        /// pinned requires the token to be the role's pane (`zmx.kill.pane`).
        case pinned
        /// ignored addresses the role alone (`zmx.kill`).
        case ignored
    }

    /// originPane is the row's local role and the origin's token for the pane `args` names.
    private func originPane(_ args: ControlArgs?, of row: Session, origin: AttachedOrigin, token rule: PaneToken)
        -> Result<(role: ZmxPaneRole, token: String), AttachedRefusal> {
        let panes: [(ZmxPaneRole, UUID?)] = [(.left, row.paneIdentity), (.right, row.splitPaneIdentity)]
        let token = rule == .ignored ? nil : args?.paneID.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let byToken = token.flatMap(UUID.init(uuidString:)).flatMap { token in panes.first { $0.1 == token } }
        let byRole = args?.pane.flatMap(ZmxPaneRole.init(controlName:)).flatMap { role in panes.first { $0.0 == role } }
        if let token, byToken == nil, rule == .strict || byRole == nil {
            return .failure(AttachedRefusal(message: "unknown pane id: \(token)"))
        }
        if rule == .pinned, let token, let (role, identity) = byRole, let identity,
           let refusal = ZmxPaneRole.pinRefusal(token, identity: identity, pane: role) {
            return .failure(AttachedRefusal(message: refusal))
        }
        guard let (role, identity) = byToken ?? byRole else {
            return .failure(AttachedRefusal(message: "name the pane with --pane left|right or --pane-id"))
        }
        guard let identity, let originToken = AttachedOrigin.originPaneID(of: row, local: identity) else {
            return .failure(AttachedRefusal(message: "no \(role.rawValue) pane of the session on \(origin.host) is attached here"))
        }
        return .success((role, originToken))
    }

    /// restartedPaneIsMounted is false for a restart of a pane this window does not lay out: no terminal here would attach
    /// to release a hold, so the origin starts it at once. The local role is the one a swap here put it in.
    private func restartedPaneIsMounted(_ request: ControlRequest, row: Session, origin: AttachedOrigin) -> Bool {
        guard request.cmd == .sessionRestart, case .success(let pane) = originPane(request.args, of: row, origin: origin, token: .strict) else {
            return true
        }
        return OverlayPane(rawValue: pane.role.rawValue).map(row.rendersPane) ?? false
    }

    /// originRole is the role the origin's pane `token` holds there, which a swap on this Mac alone does not change.
    private func originRole(of row: Session, pane token: String) -> ZmxPaneRole? {
        guard let layout = row.remotePresentation?.layout, let pane = UUID(uuidString: token), layout.panes.contains(pane) else {
            return nil
        }
        return layout.primary == pane ? .left : .right
    }

    private func terminateRoute(_ request: ControlRequest) -> RemoteRoute? {
        let targets = request.args?.targets ?? [request.target ?? "active"]
        var resolved: (store: AppStore, ids: [UUID])?
        let response = resolveBatchSessions(targets, window: request.args?.window) { store, ids in
            resolved = (store, ids)
            return ControlResponse(ok: true)
        }
        guard response.ok, let (store, ids) = resolved else { return nil }
        var groups: [TerminatePlan.Group] = []
        // every attached id goes to its origin, whose own grouping decides what else ends there
        let roots = Set(closeRoots(ids, in: store))
        var local: [UUID] = []
        for id in ids {
            guard let row = store.session(withID: id), let origin = AttachedOrigin(row) else {
                if roots.contains(id) { local.append(id) }
                continue
            }
            if let index = groups.firstIndex(where: { $0.origin.shares(origin) }) {
                groups[index] = TerminatePlan.Group(origin: groups[index].origin, sessions: groups[index].sessions + [origin.session])
            } else {
                groups.append(TerminatePlan.Group(origin: origin, sessions: [origin.session]))
            }
        }
        guard !groups.isEmpty else { return nil }
        return .attached(.terminate(TerminatePlan(groups: groups, local: local, undoable: request.args?.undoable == true,
                                                  window: library.windowID(for: store), initiated: Date())))
    }

    /// runAttached sends the plan to its origins and applies what they did here.
    func runAttached(_ plan: AttachedPlan) async -> ControlResponse {
        defer { refreshWindowCache() }
        switch plan {
        case .terminate(let terminate):
            return await runTerminate(terminate)
        case .forward(let forward, let origin, let row, let then, let attaches):
            let outcome = await runOnOrigin(forward, origin: origin, attaches: attaches)
            guard case .done(let reply) = outcome else { return Self.failure(outcome) }
            return await follow(then, reply: reply, origin: origin, row: row)
        }
    }

    private func runOnOrigin(_ forward: AttachedForward, origin: AttachedOrigin, attaches: Bool) async -> AttachedOutcome {
        guard let result = await runRemoteControl(host: origin.host, arguments: forward.words, operands: forward.operands,
                                              attaching: attaches) else {
            return .refused("invalid host")
        }
        return forward.outcome(of: result, host: origin.host)
    }

    private static func failure(_ outcome: AttachedOutcome) -> ControlResponse {
        switch outcome {
        case .done(let reply): reply
        case .refused(let reason), .unknown(let reason): ControlResponse(ok: false, error: reason)
        }
    }

    private func follow(_ then: AttachedFollowUp, reply: ControlResponse, origin: AttachedOrigin, row: UUID) async -> ControlResponse {
        switch then {
        case .none:
            return ControlResponse(ok: true, result: localResult(reply.result, row: row))
        case .select:
            if let store = library.store(forSession: row) { store.selectSession(row) }
            return ControlResponse(ok: true, result: ControlResult(id: row.uuidString))
        case .moveUnder(let parent, let index):
            guard let store = library.store(forSession: row) else {
                return ControlResponse(ok: false, error: "moved on \(origin.host), but not here: no such session")
            }
            if case .failure(let refusal) = store.moveCompanion(row, under: parent, at: index) {
                return ControlResponse(ok: false, error: "moved on \(origin.host), but not here: \(refusal.message)")
            }
            return ControlResponse(ok: true, result: ControlResult(id: row.uuidString, parent: parent.uuidString))
        case .promoteHere(let promotion):
            guard let store = library.store(forSession: row) else {
                return ControlResponse(ok: false, error: "top-level on \(origin.host), but not here: no such session")
            }
            // the origin's new group starts empty, so a stream reconnecting meanwhile cannot hand its first companion in
            // as the baseline
            if reply.ok, store.session(withID: row)?.companionsBaselined == false { store.baselineCompanions([], forSession: row) }
            if case .failure(let refusal) = store.promoteCompanion(row, to: promotion) {
                return ControlResponse(ok: false, error: "top-level on \(origin.host), but not here: \(refusal.message)")
            }
            return ControlResponse(ok: true, result: ControlResult(id: row.uuidString))
        case .attachAfter, .nestUnderCreated:
            let created = then == .attachAfter ? reply.result?.id : reply.result?.parent
            guard let created, UUID(uuidString: created) != nil else {
                return ControlResponse(ok: false, error: "\(origin.host) did it but did not name the session it created")
            }
            let attached = await attachCreated(created, host: origin.host, beside: row, atSlot: then == .nestUnderCreated)
            guard attached.ok, let local = attached.result?.id.flatMap(UUID.init(uuidString:)) else {
                return ControlResponse(ok: false, error: "created session \(created) on \(origin.host) but could not attach it: "
                                       + "\(attached.error ?? "attach failed"); `agtermctl zmx attach \(origin.host) \(created)` attaches it")
            }
            guard then == .nestUnderCreated else { return attached }
            let store = library.store(forSession: row)
            // nesting a row that moved under another session meanwhile would split that group
            guard store?.session(withID: row)?.parentID == nil else {
                return ControlResponse(ok: false, error: "converted on \(origin.host) and attached its new parent here, "
                                       + "but the row moved under another session meanwhile and stays there")
            }
            store?.nest(row, under: local)
            return ControlResponse(ok: true, result: ControlResult(id: row.uuidString, parent: local.uuidString))
        }
    }

    /// localResult is the origin's reply as this row's: its id, and a restart receipt naming this Mac's pane.
    private func localResult(_ origin: ControlResult?, row: UUID) -> ControlResult {
        var result = origin ?? ControlResult()
        result.id = row.uuidString
        if let receipt = result.restart, let token = UUID(uuidString: receipt.paneID),
           let local = library.store(forSession: row)?.session(withID: row)?.remotePresentation?.binding.localPane(forRemote: token) {
            result.restart = ControlRestartReceipt(paneID: local.uuidString, oldPid: receipt.oldPid, newPid: receipt.newPid,
                                                   replayedArgv: receipt.replayedArgv)
        }
        return result
    }

    private func runTerminate(_ plan: TerminatePlan) async -> ControlResponse {
        var closed: [String] = []
        var failures: [String] = []
        var undoable: Bool?
        if !plan.local.isEmpty {
            let reply = plan.local.count == 1
                ? closeSession(plan.local[0].uuidString, window: nil, undoable: plan.undoable)
                : closeSessions(plan.local.map(\.uuidString), window: nil, undoable: plan.undoable)
            closed += reply.result?.closed ?? []
            undoable = reply.result?.undoable
            if !reply.ok { failures.append(reply.error ?? "could not close the local sessions") }
        }
        for group in plan.groups {
            let outcome = await runOnOrigin(.terminate(sessions: group.sessions, undoable: plan.undoable), origin: group.origin, attaches: false)
            guard case .done(let reply) = outcome else {
                failures.append(Self.failure(outcome).error ?? "the terminate failed on \(group.origin.host)")
                continue
            }
            closed += closeAttachedRows(ended: Set(reply.result?.closed ?? group.sessions), origin: group.origin)
            if group.sessions.count == 1, let recentID = reply.result?.recentID {
                library.noteOriginRecentID(recentID, host: group.origin.host, sessionID: group.sessions[0])
            }
            if reply.result?.undoable == true, let undoID = reply.result?.undoID, let window = plan.window {
                library.noteAttachedUndo(AttachedUndo(host: group.origin.host, undoID: undoID, sessions: reply.result?.closed ?? group.sessions,
                                                      initiated: plan.initiated), window: window)
            }
            if plan.undoable { undoable = (undoable ?? true) && reply.result?.undoable == true }
        }
        let result = ControlResult(affected: closed.count, undoable: plan.undoable ? undoable : nil, closed: closed)
        guard failures.isEmpty else {
            let done = closed.isEmpty ? "" : "; closed \(closed.joined(separator: ", "))"
            return ControlResponse(ok: false, result: result, error: failures.joined(separator: "; ") + done)
        }
        return ControlResponse(ok: true, result: result)
    }

    /// closeAttachedRows closes every row here showing a session `origin` reports it ended, in any window, and no other.
    private func closeAttachedRows(ended: Set<String>, origin: AttachedOrigin) -> [String] {
        var rows: [ObjectIdentifier: (store: AppStore, ids: Set<UUID>)] = [:]
        for row in library.allOpenSessions() {
            guard let shown = AttachedOrigin(row), shown.shares(origin), ended.contains(shown.session),
                  let store = library.store(forSession: row.id) else { continue }
            rows[ObjectIdentifier(store), default: (store, [])].ids.insert(row.id)
        }
        return rows.values.flatMap { $0.store.closeExactly($0.ids) }.map(\.uuidString)
    }
}

extension ControlServer: RemoteAttachLines {
    /// paneAttach never claims the lead: the pane was added on the origin, whose surface keeps it until a key here.
    func paneAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String {
        let lead = ZmxLeadAttachment(claim: false)
        guard let line = try? RemoteSession.attachPaneCommand(host: origin.host, endpoint: origin.endpoint, daemon: daemon,
                                                              session: origin.sessionName, pane: .right, lead: lead) else {
            return Self.unaddressable(origin.host, what: "pane")
        }
        ZmxLeadBook.shared.begin(lead, pane: local)
        return line
    }

    /// scratchAttach never claims the lead either, as the origin's own scratch client does not.
    func scratchAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String {
        scratchAttach(origin, daemon: daemon, local: local, reclaim: nil)
    }

    func scratchAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID, reclaim: String?) -> String {
        let lead = ZmxLeadAttachment(claim: false, reclaim: reclaim)
        guard let line = try? RemoteSession.attachPaneCommand(host: origin.host, endpoint: origin.endpoint, daemon: daemon,
                                                              session: "scratch", pane: .left, lead: lead) else {
            return Self.unaddressable(origin.host, what: "scratch")
        }
        ZmxLeadBook.shared.begin(lead, pane: local)
        return line
    }

    private static func unaddressable(_ host: String, what: String) -> String {
        CommandRestore.shellQuotedLine(["/usr/bin/env", "/bin/sh", "-c",
                                        "printf '%s\\n' 'agterm: \(host) listed a \(what) agterm cannot address'; exit 1"])
    }
}
