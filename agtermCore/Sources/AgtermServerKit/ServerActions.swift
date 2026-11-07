import Foundation
import agtermCore

/// ServerActions is agterm-server's side of `ControlDispatcher`: the headless store answering as the catalog's one
/// logical window. Window arguments name that window or nothing.
@MainActor
public final class ServerActions: ControlActions {
    let store: AppStore
    let catalog: CatalogRoot
    let identity: AppIdentity
    let panes: ServerPanes
    let streams: ServerStreams
    var hudAutoHide: [UUID: HudTimer] = [:]
    /// operationsUnsaved is set while the operation table holds an entry its last write failed to save.
    var operationsUnsaved = false

    init(store: AppStore, catalog: CatalogRoot, identity: AppIdentity, panes: ServerPanes) {
        self.store = store
        self.catalog = catalog
        self.identity = identity
        self.panes = panes
        streams = ServerStreams(store: store, catalogID: catalog.id)
        streams.dispatch = { [weak self] request in
            await self?.serve(request) ?? ControlResponse(ok: false, error: "agterm-server is stopping")
        }
        wireAskOwners()
        streams.catalogVersions = catalogVersions
        streams.catalogWorkspaces = { [weak self] in self?.catalogWorkspaces() ?? [] }
    }

    /// serve refuses a command the server does not serve, then dispatches the rest: the socket's requests and a
    /// handed-over page's bridge requests alike. The catalog is published after each, whatever it changed.
    func serve(_ request: ControlRequest) async -> ControlResponse {
        if let refusal = ServerCommandPolicy.refusal(request.cmd) { return ControlResponse(ok: false, error: refusal) }
        if let opID = request.args?.opID { return await serveOperation(request, opID: opID) }
        let response = await ControlDispatcher(actions: self).dispatch(request)
            ?? ControlResponse(ok: false, error: "\(request.cmd.rawValue) is not available on agterm-server")
        streams.catalogHub.refresh()
        return response
    }

    public func claimOverlayJob(_ job: String) -> ControlResponse { streams.claimJobStream(job) }

    public func claimOverlayJob(_ job: String, token: String?) -> ControlResponse { streams.claimJobStream(job, token: token) }

    public func claimPageServe(_ token: String) -> ControlResponse { streams.claimPageStream(token) }

    public func controlTree(window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        return ControlResponse(ok: true, result: ControlResult(tree: store.controlTree(paneForeground: { _ in nil }, app: identity)))
    }

    public func appIdentity() -> ControlResponse {
        var result = ControlResult(app: identity)
        result.headless = true
        result.versions = catalogVersions
        return ControlResponse(ok: true, result: result)
    }

    public func windowList() -> ControlResponse {
        let node = ControlWindowNode(id: catalog.id.uuidString, name: catalog.name, open: true, active: true)
        return ControlResponse(ok: true, result: ControlResult(windows: [node]))
    }

    /// windowRefusal accepts no window, the catalog's id (any case) or `active`, and refuses any other.
    func windowRefusal(_ window: String?) -> ControlResponse? {
        guard let window, !window.isEmpty, window != "active",
              UUID(uuidString: window) != catalog.id else { return nil }
        return ControlResponse(ok: false, error: "window not found: \(window); agterm-server has one window, \(catalog.id.uuidString)")
    }
}

/// ActionRefusal carries the reply for a target that did not resolve.
struct ActionRefusal: Error {
    let response: ControlResponse
}

extension Result where Failure == ActionRefusal {
    static func refused(_ response: ControlResponse) -> Self { .failure(ActionRefusal(response: response)) }
}
