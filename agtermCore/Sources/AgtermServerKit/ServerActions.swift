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

    init(store: AppStore, catalog: CatalogRoot, identity: AppIdentity, panes: ServerPanes) {
        self.store = store
        self.catalog = catalog
        self.identity = identity
        self.panes = panes
    }

    public func controlTree(window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        return ControlResponse(ok: true, result: ControlResult(tree: store.controlTree(paneForeground: { _ in nil }, app: identity)))
    }

    public func appIdentity() -> ControlResponse {
        var result = ControlResult(app: identity)
        result.headless = true
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
