import Foundation

extension ControlDispatcher {
    /// `restore.mode` and the `zmx` group. Split out of `ControlDispatcher.swift` so that file stays inside
    /// the 1000-line limit, following `+Hud` and `+Pick`.
    func dispatchZmxCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .zmxTree:
            // no host is this app's own attachable sessions, which is also exactly what a `zmx tree HOST`
            // runs on the far side
            return await actions.remoteTree(host: request.args?.host?.trimmedOrNil)
        case .zmxAttach, .zmxAttachGroup:
            guard let host = request.args?.host?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a host")
            }
            // no `active` default: the target names a session on ANOTHER machine, which nothing local
            // could resolve for the caller
            guard let session = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a remote session")
            }
            // the unresolved case names the id it could not find, so a control character here would reach
            // a terminal through that message
            guard RemoteSession.isPlain(session) else {
                return ControlResponse(ok: false, error: "invalid remote session")
            }
            let window = request.args?.window?.trimmedOrNil
            let workspace: ControlAttachWorkspace?
            switch Self.attachWorkspace(request.args) {
            case .success(let value): workspace = value
            case .failure(let rejection): return ControlResponse(ok: false, error: rejection.message)
            }
            if request.cmd == .zmxAttachGroup {
                return await actions.attachRemoteGroup(host: host, session: session, window: window, workspace: workspace)
            }
            return await actions.attachRemoteSession(host: host, session: session, window: window, workspace: workspace)
        case .zmxPresent:
            // no `active` default: a viewer names the session it attached, and a guess would stream another
            guard let session = request.target?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "zmx.present requires a session")
            }
            guard RemoteSession.isPlain(session) else {
                return ControlResponse(ok: false, error: "invalid session")
            }
            return actions.openPresentation(session: session)
        default:
            return dispatchLocalZmxCommand(request)
        }
    }

    private func dispatchLocalZmxCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .restoreMode:
            guard let raw = request.args?.mode else { return actions.readRestoreMode() }
            // parsed strictly, unlike `RestoreMode`'s lossy decoder: a typo must not silently select
            // `none`, the one mode whose next launch reaps every detached daemon
            guard let mode = RestoreMode(rawValue: raw) else {
                return ControlResponse(ok: false, error: "invalid restore mode: \(raw)")
            }
            return actions.setRestoreMode(mode)
        case .zmxList:
            return actions.listZmxDaemons()
        case .zmxPrune:
            return actions.pruneZmxDaemons()
        case .zmxKill, .zmxKillPane:
            switch Self.killArguments(request) {
            case .failure(let rejection):
                return ControlResponse(ok: false, error: rejection.message)
            case .success(let kill):
                guard let paneID = kill.paneID else {
                    return actions.killZmxDaemon(target: kill.target, window: request.args?.window, pane: kill.pane)
                }
                return actions.killZmxPane(target: kill.target, window: request.args?.window, pane: kill.pane, paneID: paneID)
            }
        case .zmxScreen:
            // a daemon name, as `zmx list` prints it: the session resolver sees only open windows
            guard let name = request.args?.name?.trimmedOrNil, RemoteSession.isPlain(name) else {
                return ControlResponse(ok: false, error: "zmx.screen requires a daemon name")
            }
            switch parseBufferExtent(request.args) {
            case .rejected(let response): return response
            case .extent(let all, let lines):
                return actions.readZmxScreen(name: name, fullBuffer: all || lines != nil, lines: lines)
            }
        case .zmxReset:
            guard request.args?.force == true else {
                return ControlResponse(ok: false, error: "zmx.reset requires --force")
            }
            return actions.resetLiveSessions()

        default:
            preconditionFailure("unexpected zmx command: \(request.cmd.rawValue)")
        }
    }
}

/// ZmxKillArguments is a checked `zmx.kill` or `zmx.kill.pane`; `paneID` is set only for the pinned form.
struct ZmxKillArguments {
    let target: String
    let pane: ZmxPaneRole
    let paneID: String?
}

extension ControlDispatcher {
    /// killArguments checks a kill before any host is asked. There is no `active` or left-pane default: this destroys a
    /// backend process rather than a model object, reaching claims no window shows and every client attached to it.
    static func killArguments(_ request: ControlRequest) -> Result<ZmxKillArguments, ArgumentRejection> {
        let cmd = request.cmd.rawValue
        guard let target = request.target, !target.isEmpty else {
            return .failure(ArgumentRejection(message: "\(cmd) requires an explicit --target"))
        }
        guard let rawPane = request.args?.pane, let pane = ZmxPaneRole(controlName: rawPane) else {
            return .failure(ArgumentRejection(message: "\(cmd) requires --pane left|right"))
        }
        guard request.args?.force == true else {
            return .failure(ArgumentRejection(message: "\(cmd) requires --force"))
        }
        guard request.cmd == .zmxKillPane else { return .success(ZmxKillArguments(target: target, pane: pane, paneID: nil)) }
        guard let paneID = request.args?.paneID?.trimmedOrNil else {
            return .failure(ArgumentRejection(message: "zmx.kill.pane requires --pane-id"))
        }
        return .success(ZmxKillArguments(target: target, pane: pane, paneID: paneID))
    }

    /// attachWorkspace reads an attach's destination workspace with `session.new`'s rules and wording; nil leaves the
    /// window's current workspace.
    static func attachWorkspace(_ args: ControlArgs?) -> Result<ControlAttachWorkspace?, ArgumentRejection> {
        if args?.workspace != nil, args?.workspaceName != nil {
            return .failure(ArgumentRejection(message: "use either --workspace or --workspace-name, not both"))
        }
        if let raw = args?.workspaceName {
            guard let name = raw.trimmedOrNil else {
                return .failure(ArgumentRejection(message: "workspace name must not be blank"))
            }
            return .success(.name(name, create: args?.createWorkspace == true))
        }
        if args?.createWorkspace == true {
            return .failure(ArgumentRejection(message: "--create-workspace requires --workspace-name"))
        }
        // passed as given, so a blank id fails to resolve as on `session.new` instead of reading as omitted
        return .success(args?.workspace.map(ControlAttachWorkspace.id))
    }
}
