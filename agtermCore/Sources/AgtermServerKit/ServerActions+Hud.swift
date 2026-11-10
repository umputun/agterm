import Foundation
import agtermCore

/// HUDs on agterm-server hold the session slot with their spec only; the presenting Mac draws and measures the
/// panel from the published spec.
extension ServerActions {
    public func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        openHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    public func openHud(_ target: String?, window: String?, spec: HudSpec, placement: ControlHudPlacement) -> ControlResponse {
        withSession(target, window: window) { session in
            if session.overlayHidden { return ControlResponse(ok: false, error: OverlayVisibilityError.hidden) }
            switch session.panePlacement(placement.pane, paneID: placement.paneID, requireVisible: true,
                                         invalidPaneError: "hud pane must be left or right") {
            case .rejected(let response):
                return response
            case .resolved(let identity, _):
                guard store.openHeadlessHud(session.id, spec: spec, paneIdentity: identity) else {
                    return ControlResponse(ok: false, error: "overlay already open")
                }
                armHudAutoHide(session, spec: spec)
                return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
            }
        }
    }

    public func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        updateHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    public func updateHud(_ target: String?, window: String?, spec: HudSpec, placement: ControlHudPlacement) -> ControlResponse {
        withSession(target, window: window) { session in
            guard session.hudActive else { return ControlResponse(ok: false, error: OverlayHudError.noHud) }
            switch session.panePlacement(placement.pane, paneID: placement.paneID, requireVisible: false,
                                         invalidPaneError: "hud pane must be left or right") {
            case .rejected(let response):
                return response
            case .resolved(let identity, _):
                guard store.updateHeadlessHud(session.id, spec: spec, paneIdentity: identity) else {
                    return ControlResponse(ok: false, error: OverlayHudError.noHud)
                }
                armHudAutoHide(session, spec: spec)
                return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
            }
        }
    }

    public func closeHud(_ target: String?, window: String?) -> ControlResponse {
        withSession(target, window: window) { session in
            guard store.closeHud(session.id) else { return ControlResponse(ok: false, error: OverlayHudError.noHud) }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    /// armHudAutoHide replaces `session`'s timer with `spec`'s and publishes the panel with its deadline. The
    /// revision makes a superseded timer inert; the store's teardown cancels it through `onHudDiscarded`.
    func armHudAutoHide(_ session: Session, spec: HudSpec) {
        let id = session.id
        let revision = (hudAutoHide[id]?.revision ?? 0) + 1
        hudAutoHide[id]?.task.cancel()
        hudAutoHide[id] = nil
        let seconds = min(spec.effectiveHideAfter, HudSpec.maxHideAfter)
        if seconds > 0 {
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self, self.hudAutoHide[id]?.revision == revision else { return }
                self.hudAutoHide[id] = nil
                self.store.closeHud(id)
            }
            hudAutoHide[id] = HudTimer(revision: revision, deadline: Date().addingTimeInterval(seconds), task: task)
            session.onHudDiscarded = { [weak self] in
                MainActor.assumeIsolated {
                    self?.hudAutoHide[id]?.task.cancel()
                    self?.hudAutoHide[id] = nil
                }
            }
        }
        store.publishHud(forSession: id, expiresAt: hudAutoHide[id]?.deadline)
    }
}

/// HudTimer is one session's armed auto-hide.
struct HudTimer {
    let revision: Int
    let deadline: Date
    let task: Task<Void, Never>
}
