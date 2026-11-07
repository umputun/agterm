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
        .sessionNew, .sessionDuplicate, .sessionCompanionNew, .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionRename, .sessionClose,
        .sessionMove, .workspaceNew, .workspaceRename, .workspaceDelete, .workspaceMove,
    ]

    /// parse reads `request` against the remote window `store`, resolving its targets there. A field the server
    /// cannot be asked for from here is refused by name rather than dropped.
    @MainActor
    public static func parse(_ request: ControlRequest, in store: AppStore) -> RemoteOperationParse {
        let args = request.args ?? ControlArgs()
        // the caller's own id and epoch would be replaced by this window's, running what its epoch might refuse
        if args.opID != nil || args.epoch != nil || args.panes != nil { return refuse("operation receipts are served only by agterm-server") }
        if let field = unsupportedField(request.cmd, args) { return refuse("\(field) is not available in a remote window") }
        let select = args.noSelect != true
        let shell = RemoteShellOptions(name: args.name, cwd: args.cwd, command: args.command)
        switch request.cmd {
        case .sessionNew:
            if args.after != nil, args.before != nil { return refuse("use either --after or --before, not both") }
            guard let anchor = args.after ?? args.before else {
                return workspace(args.workspace, in: store) { .operation(.newSession(workspace: $0, shell: shell), select: select) }
            }
            if args.workspace != nil { return refuse("session.new takes --after/--before or a workspace, not both") }
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
        case .sessionSplit:
            if let axis = args.axis, SplitAxis(rawValue: axis) == nil { return refuse("invalid split axis: \(axis) (vertical|horizontal)") }
            guard let mode = ControlToggleMode.parse(args.mode) else { return refuse("session.split mode must be on, off or toggle") }
            return session(request.target, in: store) { id in
                let shown = mode == .on || (mode == .toggle && store.session(withID: id)?.isSplit != true)
                return .operation(.setSplit(id, shown: shown, axis: args.axis), select: false)
            }
        case .sessionSplitClose:
            return session(request.target, in: store) { .operation(.closeSplit($0), select: false) }
        case .sessionSwap:
            return session(request.target, in: store) { .operation(.swap($0), select: false) }
        case .sessionRename:
            guard let name = args.name else { return refuse("session.rename requires a name") }
            return session(request.target, in: store) { .operation(.renameSession($0, name: name), select: false) }
        case .sessionClose:
            guard let target = singleTarget(request) else { return refuse("a remote window closes one session at a time") }
            // a close terminates on the server, so it reaches a row this window detached as well as a shown one
            let catalog = store.remoteActions?.mirror.catalog?.workspaces.flatMap(\.sessions).map(\.id)
            return session(target, in: store, candidates: catalog) { .operation(.closeSession($0), select: false) }
        case .sessionMove:
            guard let target = singleTarget(request) else { return refuse("a remote window moves one session at a time") }
            return session(target, in: store) { id in move(id, args, in: store) }
        case .workspaceNew:
            return .operation(.newWorkspace(name: args.name), select: false)
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

    @MainActor
    private static func move(_ id: UUID, _ args: ControlArgs, in store: AppStore) -> RemoteOperationParse {
        if args.after != nil, args.before != nil { return refuse("use either --after or --before, not both") }
        let placements = [args.after != nil || args.before != nil, args.to != nil, args.workspace != nil].filter { $0 }.count
        guard placements == 1 else { return refuse("session.move takes exactly one of --to, a workspace, or --after/--before") }
        if let anchor = args.after ?? args.before {
            return session(anchor, in: store) { anchorID in
                .operation(.moveSession(id, to: args.after != nil ? .after(anchorID) : .before(anchorID)), select: false)
            }
        }
        if let to = args.to {
            guard ReorderDirection(rawValue: to) != nil else { return refuse("session.move --to must be up|down|top|bottom") }
            return .operation(.moveSession(id, to: .step(to)), select: false)
        }
        return workspace(args.workspace, in: store) { .operation(.moveSession(id, to: .workspace($0)), select: false) }
    }

    private static func unsupportedField(_ cmd: Command, _ args: ControlArgs) -> String? {
        let tinted = args.tint != nil || args.tintOn != nil
        let fields: [(Bool, String)] = switch cmd {
        case .sessionNew:
            [(args.workspaceName != nil, "--workspace-name"), (args.createWorkspace == true, "--create-workspace"),
             (args.wait == true, "--wait"), (tinted, "--tint")]
        case .sessionCompanionNew: [(args.wait == true, "--wait"), (tinted, "--tint")]
        case .sessionClose: [(args.undoable == true, "--undoable")]
        case .workspaceNew: [(args.collapsed == true, "--collapsed"), (tinted, "--tint")]
        default: []
        }
        return fields.first { $0.0 }?.1
    }

    /// singleTarget is the request's one target, from `target` or a one-element `targets`; nil for a batch.
    private static func singleTarget(_ request: ControlRequest) -> String? {
        guard let targets = request.args?.targets else { return request.target ?? "active" }
        return targets.count == 1 ? targets[0] : nil
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
