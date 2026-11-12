import Foundation
import agtermCore

/// RemoteRoute is where a control request on a remote window's rows goes: to the window's server, or refused here.
enum RemoteRoute: Sendable {
    case send(RemoteCatalogActions, PreparedRemoteOperation, select: Bool)
    case pageResult(host: String, page: UUID)
    case refused(ControlResponse)
}

extension ControlServer {
    /// localOnlyCommands make shells or rows on this Mac, which a remote window shows only from its server.
    static let localOnlyCommands: Set<Command> = [
        .sessionCompanionDuplicate, .sessionCompanionConvert, .zmxAttach, .zmxAttachGroup, .recentOpen,
    ]

    /// remoteRoute reads `request` once, on the main actor, before it is dispatched: nil runs it here as usual; a
    /// route sends it to the server off the accept thread, with what it was decided on captured now.
    func remoteRoute(_ request: ControlRequest) -> RemoteRoute? {
        if request.cmd == .sessionClose, let target = request.args?.targets?.first ?? request.target, target.lowercased() != "active" {
            return closeRoute(request, target: target)
        }
        if request.cmd == .sessionOverlayClose, request.args?.pane == nil, let route = pageRowCloseRoute(request) { return route }
        if request.cmd == .sessionOverlayResult, let page = request.args?.page.flatMap(UUID.init(uuidString:)),
           HtmlPageOutcomes.shared.outcome(for: page) == nil, let host = forwardedPages[page] {
            return .pageResult(host: host, page: page)
        }
        let structural = RemoteOperation.structuralCommands.contains(request.cmd)
        guard structural || Self.localOnlyCommands.contains(request.cmd),
              let store = routedStore(request), let actions = store.remoteActions else { return nil }
        guard structural else {
            return .refused(ControlResponse(ok: false, error: "\(request.cmd.rawValue) is not available in a remote window"))
        }
        return route(request, in: store, actions: actions)
    }

    /// closeRoute resolves a close by id once over local rows and remote catalogs, so a detached row is reachable and a
    /// prefix it shares with a row elsewhere stays ambiguous.
    private func closeRoute(_ request: ControlRequest, target: String) -> RemoteRoute? {
        switch library.resolveCloseTarget(target, window: request.args?.window) {
        case .local, .unresolvedWindow:
            return nil
        case .refused(let error):
            return .refused(ControlResponse(ok: false, error: error))
        case .remote(let store, _):
            guard let actions = store.remoteActions else { return nil }
            return route(request, in: store, actions: actions)
        }
    }

    /// pageRowCloseRoute closes a server page row on its server, as its page's own close does; a page row attached
    /// from another Mac keeps the local close, which ends only this view.
    private func pageRowCloseRoute(_ request: ControlRequest) -> RemoteRoute? {
        guard case .success(let (store, id)) = resolver.resolveSessionTarget(request.target, window: request.args?.window),
              let actions = store.remoteActions, let row = store.session(withID: id), row.content == .page,
              row.remotePresentation?.binding.catalogOwned == true else { return nil }
        return route(ControlRequest(cmd: .sessionClose, target: id.uuidString), in: store, actions: actions)
    }

    private func route(_ request: ControlRequest, in store: AppStore, actions: RemoteCatalogActions) -> RemoteRoute {
        // a page row lists no pane, which preparation would read as an ended session
        if let refusal = pageCompanionRefusal(request) { return .refused(refusal) }
        switch RemoteOperation.parse(request, in: store) {
        case .refused(let response):
            return .refused(response)
        case .operation(let operation, let select):
            switch actions.prepare(operation) {
            case .refused(let response): return .refused(response)
            case .ready(let prepared): return .send(actions, prepared, select: select)
            }
        }
    }

    /// runRemoteRoute answers a routed request with the server's reply; a created row is selected once it arrives.
    func runRemoteRoute(_ route: RemoteRoute) async -> ControlResponse {
        switch route {
        case .refused(let response):
            return response
        case .send(let actions, let prepared, let select):
            defer { refreshWindowCache() }
            let reply = await actions.send(prepared, selectingCreated: select)
            if case .newPage = prepared.operation, reply.ok, let page = reply.result?.pageID.flatMap(UUID.init(uuidString:)) {
                forwardedPages[page] = actions.mirror.host
            }
            return reply
        case .pageResult(let host, let page):
            return await serverPageResult(page, host: host)
        }
    }

    // a server page's outcome lives on the server, the replica shown here holding only a view of it
    private func serverPageResult(_ page: UUID, host: String) async -> ControlResponse {
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["session", "overlay", "result",
                                                                                   "--page", page.uuidString]) else {
            return ControlResponse(ok: false, error: "\(host) cannot be addressed")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            return ControlResponse(ok: false, error: "\(host) did not answer for page \(page.uuidString)")
        }
        return reply
    }

    /// routedStore is the store the local dispatch would act on for `request`: the target's owner, or the
    /// placement window for a command that creates a row.
    private func routedStore(_ request: ControlRequest) -> AppStore? {
        let window = request.args?.window
        switch request.cmd {
        case .sessionNew, .workspaceNew, .zmxAttach, .zmxAttachGroup, .recentOpen:
            return resolver.placementStore(window)
        case .workspaceRename, .workspaceDelete, .workspaceMove:
            return resolver.workspaceStore(request.target, window: window)
        default:
            let target = request.args?.targets?.first ?? request.target
            guard case .success(let (store, _)) = resolver.resolveSessionTarget(target, window: window) else { return nil }
            return store
        }
    }
}
