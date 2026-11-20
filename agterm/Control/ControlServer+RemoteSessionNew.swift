import Foundation
import agtermCore

/// RemoteSessionOrigin is what a host answered when asked where a new session can be made on it.
enum RemoteSessionOrigin {
    case mac([ControlWindowNode])
    case server
    case failed(String)
}

/// RemoteSessionDestination is where the new session's row goes here, taken before any picker or ssh wait so a
/// selection that changes meanwhile cannot move it.
struct RemoteSessionDestination {
    let store: AppStore
    let workspace: UUID
    /// name is the workspace the origin creates in by default; nil for the root, which the origin's root takes.
    let name: String?
}

extension RemoteSessionDestination {
    @MainActor
    init(store: AppStore, workspace: Workspace) {
        self.init(store: store, workspace: workspace.id, name: workspace.isRoot ? nil : workspace.name)
    }
}

extension ControlServer {
    func newRemoteSession(_ request: RemoteSessionCreate) async -> ControlResponse {
        let destination: RemoteSessionDestination
        switch remoteSessionDestination(window: request.window) {
        case .failure(let response): return response
        case .success(let captured): destination = captured
        }
        let origin: RemoteSessionCreate.Origin
        switch await remoteSessionOrigin(host: request.host) {
        case .failed(let reason):
            return ControlResponse(ok: false, error: reason)
        case .server:
            guard request.originWindow == nil else {
                return ControlResponse(ok: false, error: "\(request.host) runs agterm-server, which has no windows to name")
            }
            origin = .server
        case .mac(let windows):
            switch RemoteOriginWindow.choose(host: request.host, windows: windows, requested: request.originWindow) {
            case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message)
            case .success(let window): origin = .mac(window: window.id)
            }
        }
        return await createRemoteSession(request, origin: origin, destination: destination)
    }

    /// remoteSessionDestination is the current workspace of `window`, the frontmost one when nil.
    func remoteSessionDestination(window: String?) -> ControlTargetResolver.Resolution<RemoteSessionDestination> {
        let store: AppStore
        switch resolveOpenWindow(window) {
        case .failure(let response): return .failure(response)
        case .success(let (_, resolved)): store = resolved
        }
        guard let id = store.currentWorkspaceID, let workspace = store.workspaces.first(where: { $0.id == id }) else {
            return .failure(ControlResponse(ok: false, error: "no workspace to attach into"))
        }
        return .success(RemoteSessionDestination(store: store, workspace: workspace))
    }

    /// remoteSessionOrigin asks `host` what it is. Nothing here retries or treats silence as a server: a host that
    /// does not say it is a Live Mac or agterm-server gets nothing created on it.
    func remoteSessionOrigin(host: String) async -> RemoteSessionOrigin {
        guard let probe = try? RemoteSession.controlCommand(host: host, arguments: ["version"]) else { return .failed("invalid host") }
        let version = await remoteRunner.run(probe, deadline: 15)
        guard version.status == 0, let answer = try? JSONDecoder().decode(ControlResponse.self, from: Data(version.stdout.utf8)) else {
            return .failed("\(host) did not answer; nothing was created")
        }
        switch RemoteSessionCreate.originKind(answer.result, host: host) {
        case .failure(let refusal): return .failed(refusal.message)
        case .success(.server): return .server
        case .success(.mac):
            guard let windows = await originWindows(host: host) else { return .failed("\(host) did not list its windows") }
            return .mac(windows)
        }
    }

    /// createRemoteSession runs the origin's `session new` once, then attaches the session it names into
    /// `destination`. A creation whose outcome is unknown is reported, never resent.
    func createRemoteSession(_ request: RemoteSessionCreate, origin: RemoteSessionCreate.Origin,
                             destination: RemoteSessionDestination, progress: (String) -> Void = { _ in }) async -> ControlResponse {
        let host = request.host
        let arguments = request.arguments(origin: origin, workspaceName: request.workspaceName ?? destination.name)
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: arguments) else {
            return ControlResponse(ok: false, error: "invalid host")
        }
        progress("creating a session on \(host)…")
        let result = await remoteRunner.run(argv, deadline: Self.remoteCompanionDeadline)
        if result.refusedArguments {
            return ControlResponse(ok: false, error: "the agterm on \(host) is too old to create sessions for another Mac")
        }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return ControlResponse(ok: false, error: "\(host) gave no answer\(stderr.isEmpty ? "" : " (\(stderr))"); "
                                   + "whether the session was created there is unknown")
        }
        if result.status != 0, reply.ok, let created = reply.result?.id, UUID(uuidString: created) != nil {
            return ControlResponse(ok: false, error: "created session \(created) on \(host) but the connection failed before "
                                   + "attaching it; `agtermctl zmx attach \(host) \(created)` attaches it")
        }
        guard result.status == 0, reply.ok else {
            return ControlResponse(ok: false, error: reply.error ?? "the remote command failed on \(host)")
        }
        // the id reaches an error message, so only a well-formed one is echoed
        guard let created = reply.result?.id, UUID(uuidString: created) != nil else {
            return ControlResponse(ok: false, error: "\(host) created a session but did not name it")
        }
        progress("attaching the session…")
        let outcome = await attachWhenListed(created, host: host, closed: "the window or workspace to attach into was closed") { [library] in
            guard library.windowID(for: destination.store) != nil,
                  destination.store.workspaces.contains(where: { $0.id == destination.workspace }) else { return nil }
            return RemotePlacement(store: destination.store, workspace: destination.workspace)
        }
        switch outcome {
        case .attached(let response):
            return response
        case .failed(let reason):
            return ControlResponse(ok: false, error: "created session \(created) on \(host) but could not attach it: "
                                   + "\(reason); `agtermctl zmx attach \(host) \(created)` attaches it")
        }
    }
}
