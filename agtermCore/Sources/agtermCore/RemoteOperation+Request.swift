import Foundation

/// RemoteOperationParse is a control request read as a remote window's operation, or the refusal to answer with.
/// `select` says whether a created row is selected once the window shows it.
public enum RemoteOperationParse: Equatable, Sendable {
    case operation(RemoteOperation, select: Bool)
    case refused(ControlResponse)
}

extension RemoteOperation {
    /// structuralCommands are the commands a remote window sends to its server instead of running on this Mac.
    public static let structuralCommands: Set<Command> = [
        .sessionNew, .sessionDuplicate, .sessionCompanionNew, .sessionCompanionPage, .sessionPage, .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionRename, .sessionClose, .sessionTerminate,
        .sessionMove, .sessionScratch, .workspaceNew, .workspaceRename, .workspaceDelete, .workspaceMove,
        .sessionFlag, .sessionTint, .workspaceFlag, .workspaceTint,
        .sessionRestart, .sessionCompanionDuplicate, .sessionCompanionConvert, .zmxKill, .zmxKillPane,
    ]

    /// markCommands set flag and tint, which only a server carrying them in its catalog keeps.
    static let markCommands: Set<Command> = [.sessionFlag, .sessionTint, .workspaceFlag, .workspaceTint]

    /// runsLocally is whether a structural command still runs on this Mac in the remote window `store`: a flagged
    /// order, which is each Mac's own, and flag or tint against a server that does not keep them.
    @MainActor
    public static func runsLocally(_ request: ControlRequest, in store: AppStore) -> Bool {
        guard markCommands.contains(request.cmd) else { return false }
        if request.cmd == .sessionFlag, request.args?.mode == "move" { return true }
        return store.remoteActions?.mirror.ownsFlags != true
    }

    /// parse reads `request` against the remote window `store`, resolving its targets there. A field the server
    /// cannot be asked for from here is refused by name rather than dropped.
    @MainActor
    public static func parse(_ request: ControlRequest, in store: AppStore) -> RemoteOperationParse {
        let args = request.args ?? ControlArgs()
        // the caller's own id and epoch would be replaced by this window's, running what its epoch might refuse
        if args.opID != nil || args.epoch != nil || args.panes != nil || args.scratch != nil { return refuse("operation receipts are served only by agterm-server") }
        let select = args.noSelect != true
        var shell = RemoteShellOptions(name: args.name, cwd: args.cwd, command: args.command, wait: args.wait == true)
        switch request.cmd {
        case .sessionNew, .sessionCompanionNew, .workspaceNew:
            switch ControlDispatcher.creationTint(args) {
            case .success(let tint): shell.tint = tint
            case .failure(let rejection): return refuse(rejection.message)
            }
        default: break
        }
        switch request.cmd {
        case .sessionNew:
            if args.after != nil, args.before != nil { return refuse("use either --after or --before, not both") }
            if args.after != nil || args.before != nil, args.workspace != nil || args.workspaceName != nil {
                return refuse("session.new takes --after/--before or a workspace, not both")
            }
            if args.workspace != nil, args.workspaceName != nil { return refuse("use either --workspace or --workspace-name, not both") }
            if args.createWorkspace == true, args.workspaceName == nil { return refuse("--create-workspace requires --workspace-name") }
            if let name = args.workspaceName {
                return .operation(.newSessionInNamedWorkspace(name: name, create: args.createWorkspace == true, shell: shell), select: select)
            }
            guard let anchor = args.after ?? args.before else {
                return workspace(args.workspace, in: store) { .operation(.newSession(workspace: $0, shell: shell), select: select) }
            }
            return session(anchor, in: store) { id in
                guard let workspace = store.sessionLocation(ofSession: id)?.workspace else { return refuse("no such session") }
                let placement: RemoteSessionPlacement = args.after != nil ? .after(id) : .before(id)
                return .operation(.newSession(workspace: workspace, anchor: placement, shell: shell), select: select)
            }
        case .sessionDuplicate:
            // the server makes a fresh shell after the row, in the directory the catalog reports for it
            return session(request.target, in: store) { id in
                guard let workspace = store.sessionLocation(ofSession: id)?.workspace else { return refuse("no such session") }
                let shell = RemoteShellOptions(cwd: store.session(withID: id)?.focusedCwd)
                return .operation(.newSession(workspace: workspace, anchor: .after(id), shell: shell), select: true)
            }
        case .sessionCompanionNew:
            if args.workspace != nil || args.after != nil || args.before != nil {
                return refuse("a companion takes no workspace or placement: it lands under its parent")
            }
            return session(request.target, in: store) { .operation(.newCompanion(parent: $0, shell: shell), select: select) }
        case .sessionCompanionPage, .sessionPage:
            let companion = request.cmd == .sessionCompanionPage
            let row = companion ? "page companion" : "page session"
            let needsPage = companion ? OverlayHtmlError.companionNeedsPage : OverlayHtmlError.pageSessionNeedsPage
            switch ControlDispatcher.pageRowOptions(args, row: row, needsPage: needsPage) {
            case .rejected(let response): return .refused(response)
            case .options(let options):
                guard let page = RemotePageOptions(options) else { return refuse(needsPage) }
                return session(request.target, in: store) {
                    .operation(.newPage(anchor: $0, companion: companion, page: page), select: options.follow)
                }
            }
        case .sessionSplit:
            if let axis = args.axis, SplitAxis(rawValue: axis) == nil { return refuse("invalid split axis: \(axis) (vertical|horizontal)") }
            guard let mode = ControlToggleMode.parse(args.mode) else { return refuse("session.split mode must be on, off or toggle") }
            return session(request.target, in: store) { id in
                let shown = mode == .on || (mode == .toggle && store.session(withID: id)?.isSplit != true)
                return .operation(.setSplit(id, shown: shown, axis: args.axis), select: false)
            }
        case .sessionScratch:
            guard let mode = ControlToggleMode.parse(args.mode) else { return refuse("invalid scratch mode: \(args.mode ?? "toggle")") }
            return session(request.target, in: store) { id in
                let shown = mode.desiredValue(current: store.session(withID: id)?.scratchDaemon?.shown == true)
                let command = shown ? args.command.flatMap { $0.isEmpty ? nil : $0 } : nil
                return .operation(.setScratch(id, shown: shown, command: command), select: shown && args.follow == true)
            }
        case .sessionSplitClose:
            return session(request.target, in: store) { .operation(.closeSplit($0), select: false) }
        case .sessionSwap:
            return session(request.target, in: store) { .operation(.swap($0), select: false) }
        case .sessionRename:
            guard let name = args.name else { return refuse("session.rename requires a name") }
            return session(request.target, in: store) { .operation(.renameSession($0, name: name), select: false) }
        case .sessionClose, .sessionTerminate:
            // a close terminates on the server, so it reaches a row this window detached as well as a shown one
            let catalog = store.remoteActions?.mirror.catalog?.workspaces.flatMap(\.sessions).map(\.id)
            if request.args?.targets?.isEmpty == true { return refuse("\(request.cmd.rawValue) requires at least one --target") }
            guard let targets = request.args?.targets, targets.count > 1 else {
                return session(singleTarget(request), in: store, candidates: catalog) {
                    .operation(.closeSession($0, undoable: args.undoable == true), select: false)
                }
            }
            return sessions(targets, in: store, candidates: catalog) { .operation(.closeSessions($0, undoable: args.undoable == true), select: false) }
        case .sessionMove:
            if request.args?.targets?.isEmpty == true { return refuse("session.move requires at least one --target") }
            guard let targets = request.args?.targets, targets.count > 1 else {
                return session(singleTarget(request), in: store) { id in move([id], args, in: store) }
            }
            return sessions(targets, in: store) { ids in move(ids, args, in: store) }
        case .sessionFlag:
            return flag(request, in: store)
        case .sessionRestart:
            return restart(request, in: store)
        case .sessionCompanionDuplicate:
            return session(request.target, in: store) { .operation(.duplicateCompanion($0), select: select) }
        case .sessionCompanionConvert:
            // the converted row keeps its id and the selection, as a local convert leaves them
            return session(request.target, in: store) { .operation(.convertCompanion($0), select: false) }
        case .zmxKill, .zmxKillPane:
            return kill(request, in: store)
        case .sessionTint, .workspaceTint:
            switch ControlDispatcher.tintUpdate(args, command: request.cmd.rawValue) {
            case .failure(let rejection): return refuse(rejection.message)
            case .success(let update) where request.cmd == .workspaceTint:
                return workspace(request.target, in: store) { .operation(.setWorkspaceTint($0, update), select: false) }
            case .success(let update):
                return session(request.target, in: store) { .operation(.setTint($0, update), select: false) }
            }
        case .workspaceFlag:
            guard let mode = ControlToggleMode.parse(args.mode) else { return refuse("invalid workspace flag mode: \(args.mode ?? "toggle")") }
            return workspace(request.target, in: store) { id in
                .operation(.setWorkspaceFlag(id, on: mode.desiredValue(current: store.workspaceAllFlagged(id))), select: false)
            }
        case .workspaceNew:
            return .operation(.newWorkspace(name: args.name, collapsed: args.collapsed == true, tint: shell.tint), select: false)
        case .workspaceRename:
            guard let name = args.name?.trimmedOrNil else { return refuse("workspace.rename requires a name") }
            return workspace(request.target, in: store) { .operation(.renameWorkspace($0, name: name), select: false) }
        case .workspaceDelete:
            return workspace(request.target, in: store) { .operation(.deleteWorkspace($0), select: false) }
        case .workspaceMove:
            guard let to = args.to, ReorderDirection(rawValue: to) != nil else {
                return refuse("workspace.move --to must be up|down|top|bottom")
            }
            return workspace(request.target, in: store) { .operation(.moveWorkspace($0, to: to), select: false) }
        default:
            return refuse("\(request.cmd.rawValue) is not sent to a remote window's server")
        }
    }

    /// dropPlacement is a sidebar drop of `id` at `destination`, an index among `workspace`'s other sessions, as the
    /// anchor the server places it by.
    public static func dropPlacement(of id: UUID, workspace: UUID, sessions: [UUID], destination: Int) -> RemoteSessionPlacement {
        let others = sessions.filter { $0 != id }
        if destination < others.count { return .before(others[max(destination, 0)]) }
        return others.last.map { .after($0) } ?? .workspace(workspace)
    }

    /// workspaceStep is a workspace drop from `source` to `destination` among `count` workspaces as the one
    /// `workspace.move --to` step that lands it there; nil when no single step does.
    public static func workspaceStep(from source: Int, to destination: Int, count: Int) -> String? {
        switch destination {
        case source: nil
        case 0: "top"
        case count - 1: "bottom"
        case source - 1: "up"
        case source + 1: "down"
        default: nil
        }
    }

    /// move places `ids` as one server command, or as the single-row move a lone target always was.
    @MainActor
    private static func move(_ ids: [UUID], _ args: ControlArgs, in store: AppStore) -> RemoteOperationParse {
        if args.after != nil, args.before != nil { return refuse("use either --after or --before, not both") }
        let placements = [args.after != nil || args.before != nil, args.to != nil, args.workspace != nil].filter { $0 }.count
        guard placements == 1 else { return refuse("session.move takes exactly one of --to, a workspace, or --after/--before") }
        let operation = { (placement: RemoteSessionPlacement) -> RemoteOperationParse in
            .operation(ids.count == 1 ? .moveSession(ids[0], to: placement) : .moveSessions(ids, to: placement), select: false)
        }
        if let anchor = args.after ?? args.before {
            return session(anchor, in: store) { operation(args.after != nil ? .after($0) : .before($0)) }
        }
        if let to = args.to {
            guard ReorderDirection(rawValue: to) != nil else { return refuse("session.move --to must be up|down|top|bottom") }
            guard ids.count == 1 else { return refuse("session.move --to takes one session") }
            return operation(.step(to))
        }
        return workspace(args.workspace, in: store) { operation(.workspace($0)) }
    }

    /// flag sends `on` or `off` decided against the server's own flag, never `toggle`, so a second writer racing
    /// this one cannot invert it twice.
    @MainActor
    private static func flag(_ request: ControlRequest, in store: AppStore) -> RemoteOperationParse {
        let mode = request.args?.mode ?? "toggle"
        if request.args?.before != nil || request.args?.after != nil { return refuse("--before and --after apply only to session.flag move") }
        if mode == "clear" { return .operation(.clearFlags, select: false) }
        return session(request.target, in: store) { id in
            let flagged = store.remoteActions?.mirror.catalog?.session(id)?.fields.flagged ?? store.session(withID: id)?.flagged == true
            switch mode {
            case "on": return .operation(.setFlag(id, on: true), select: false)
            case "off": return .operation(.setFlag(id, on: false), select: false)
            case "toggle": return .operation(.setFlag(id, on: !flagged), select: false)
            default: return refuse("invalid flag mode: \(mode)")
            }
        }
    }

    /// restart names the pane by role, resolving a token against the row this window shows, since the server
    /// knows only its own panes' tokens.
    @MainActor
    private static func restart(_ request: ControlRequest, in store: AppStore) -> RemoteOperationParse {
        switch ControlDispatcher.restartOptions(request.args) {
        case .failure(let rejection):
            return refuse(rejection.message)
        case .success(let options):
            return session(request.target, in: store) { id in
                guard let row = store.session(withID: id) else { return refuse("no such session") }
                if let token = options.paneID, row.paneRole(forToken: token) == nil { return refuse("unknown pane id: \(token)") }
                let role = options.paneID.flatMap(row.paneRole(forToken:)) ?? options.pane
                guard let pane = role.flatMap({ ZmxPaneRole(controlName: $0.rawValue) }) else {
                    return refuse("session.restart does not address the scratch pane")
                }
                return .operation(.restart(id, pane: pane, command: options.command), select: false)
            }
        }
    }

    /// kill keeps the local refusals: nothing about destroying a daemon falls back to what is in front of the user.
    @MainActor
    private static func kill(_ request: ControlRequest, in store: AppStore) -> RemoteOperationParse {
        let cmd = request.cmd.rawValue
        guard let target = request.target, !target.isEmpty else { return refuse("\(cmd) requires an explicit --target") }
        guard target != "active" else { return refuse("\(cmd) needs a session id; 'active' is not accepted") }
        guard request.args?.window != "active" else { return refuse("\(cmd) needs a window id; 'active' is not accepted") }
        guard let raw = request.args?.pane, let pane = ZmxPaneRole(controlName: raw) else { return refuse("\(cmd) requires --pane left|right") }
        guard request.args?.force == true else { return refuse("\(cmd) requires --force") }
        let paneID = request.args?.paneID
        if request.cmd == .zmxKillPane, paneID?.isEmpty != false { return refuse("zmx.kill.pane requires --pane-id") }
        return session(target, in: store) {
            .operation(.killDaemon($0, pane: pane, paneID: request.cmd == .zmxKillPane ? paneID : nil), select: false)
        }
    }

    /// singleTarget is the request's one target, from `target` or a one-element `targets`.
    private static func singleTarget(_ request: ControlRequest) -> String {
        request.args?.targets?.first ?? request.target ?? "active"
    }

    @MainActor
    private static func session(_ target: String?, in store: AppStore, candidates: [UUID]? = nil,
                                _ body: (UUID) -> RemoteOperationParse) -> RemoteOperationParse {
        let target = target ?? "active"
        let resolution = ControlResolve.resolve(target, candidates: candidates ?? store.workspaces.flatMap { $0.sessions.map(\.id) },
                                                active: store.selectedSessionID)
        guard case .resolved(let id) = resolution else {
            return refuse(ControlResolve.errorMessage(noun: "session", target: target, resolution: resolution))
        }
        return body(id)
    }

    /// sessions resolves batch targets in order, deduplicated; one unresolved target refuses the batch.
    @MainActor
    private static func sessions(_ targets: [String], in store: AppStore, candidates: [UUID]? = nil,
                                 _ body: ([UUID]) -> RemoteOperationParse) -> RemoteOperationParse {
        var ids: [UUID] = []
        for target in targets {
            let resolution = ControlResolve.resolve(target, candidates: candidates ?? store.workspaces.flatMap { $0.sessions.map(\.id) },
                                                    active: store.selectedSessionID)
            guard case .resolved(let id) = resolution else {
                return refuse(ControlResolve.errorMessage(noun: "session", target: target, resolution: resolution))
            }
            if !ids.contains(id) { ids.append(id) }
        }
        return body(ids)
    }

    @MainActor
    private static func workspace(_ target: String?, in store: AppStore, _ body: (UUID) -> RemoteOperationParse) -> RemoteOperationParse {
        let target = target ?? "active"
        let resolution = ControlResolve.resolve(target, candidates: store.workspaces.map(\.id), active: store.currentWorkspaceID)
        guard case .resolved(let id) = resolution else {
            return refuse(ControlResolve.errorMessage(noun: "workspace", target: target, resolution: resolution))
        }
        return body(id)
    }

    private static func refuse(_ error: String) -> RemoteOperationParse {
        .refused(ControlResponse(ok: false, error: error))
    }
}
