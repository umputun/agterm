import Foundation
import agtermCore

extension ControlServer {
    /// `result.text` names the state the scoped overlays were left in, `hidden` or `shown`, which is how a
    /// toggle reports the way it went.
    func setSessionOverlayVisibility(_ target: String?, window: String?, pane: OverlayPane?,
                                     mode: OverlayVisibilityMode) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            if let failure = store.applyOverlayVisibility(id, pane: pane, mode: mode) {
                return ControlResponse(ok: false, error: failure.message)
            }
            let shown = store.session(withID: id)?.anyOverlayShown(pane) ?? false
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: shown ? "shown" : "hidden"))
        }
    }
}
