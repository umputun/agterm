import Foundation
import os
import agtermCore

private let remoteLogger = Logger(subsystem: "com.umputun.agterm", category: "RemotePresentation")

/// The viewer's side of a mirrored HUD: the origin's panel shown through this app's own HUD path, so it is
/// sized to this Mac's pane, painted by the bundled helper, and comes down on this Mac's own timer.
extension ControlServer {
    /// Shows, updates or removes the HUD mirrored from `id`'s origin. `nil` removes it.
    ///
    /// Only a panel the bridge opened is ever replaced or closed. A program overlay in the slot refuses the
    /// open, and the mirrored panel simply yields to it.
    func showRemoteHud(_ hud: PresentationHud?, forSession id: UUID) {
        guard let store = library.store(forSession: id), let session = store.session(withID: id),
              session.remotePresentation != nil else { return }
        // zero remaining means the origin's panel is already due down; showing it would outlive it
        guard let hud, hud.remaining != 0 else {
            store.closeBridgedHud(forSession: id)
            return
        }
        // this Mac counts down what is left of the origin's interval, not the configured one again
        let spec = HudSpec(message: hud.spec.message, detail: hud.spec.detail, spinner: hud.spec.spinner,
                           backgroundColor: hud.spec.backgroundColor, textColor: hud.spec.textColor,
                           sizePercent: hud.spec.sizePercent, position: hud.spec.position,
                           hideAfter: hud.remaining)
        // resolved the same way for an open and an update: `hud.update` accepts a pane the deck does not
        // lay out, which would move a panel already shown session-wide onto a hidden pane and unmount it
        let pane = store.localPane(hud.pane, in: session).flatMap { session.rendersPane($0) ? $0 : nil }
        let placement = ControlHudPlacement(pane: pane)
        let target = id.uuidString
        let bridged = session.hudActive && session.remotePresentation?.hudBridged == true
        // `hud.open` replaces a live HUD, so a panel this Mac's own program put up has to be left alone here
        guard bridged || !session.hudActive else { return }
        let response = bridged
            ? updateHud(target, window: nil, spec: spec, placement: placement)
            : openRemoteHud(target, spec: spec, placement: placement)
        guard response.ok else {
            remoteLogger.notice("mirrored HUD not shown for \(id, privacy: .public): \(response.error ?? "unknown", privacy: .public)")
            return
        }
        store.markHudBridged(forSession: id)
    }
}
