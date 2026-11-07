import Foundation
import agtermCore

extension ControlServer {
    /// installRemoteLinkClicks points the link opener's forward and refuse hooks at this server.
    func installRemoteLinkClicks() {
        LinkOpener.shared.forward = { [weak self] click in self?.forwardRemoteLinkClick(click) ?? .notOpened }
        LinkOpener.shared.refuse = { [weak self] session, reason in self?.refuseRemoteLinkClick(reason, session: session) }
    }

    /// forwardRemoteLinkClick sends a path clicked in an attached pane to its origin; nil when sent, else why not.
    func forwardRemoteLinkClick(_ click: RemoteLinkClick) -> RemoteLinkRefusal? {
        guard let store = library.store(forSession: click.session) else { return .notPresenter }
        let client = remoteClients[click.session]
        let supported = client?.originSupports(PresentationHub.linkClickKind) == true
        switch store.linkClickRequest(click, originSupportsClick: supported, hidden: remoteLinkPageHidden(click.session)) {
        case .failure(let reason): return reason
        case .success(let frame):
            client?.answer(.linkClick(frame))
            return nil
        }
    }

    /// refuseRemoteLinkClick reports a click that was not carried out with a panel that hides itself, as a failed
    /// attach does, or with the alert sound when that panel would replace another HUD or not be seen.
    func refuseRemoteLinkClick(_ reason: RemoteLinkRefusal, session id: UUID) {
        if reason != .hidden, !remoteLinkPageHidden(id), let host = library.store(forSession: id)?.session(withID: id)?.remoteHost {
            let spec = HudSpec(message: reason.message(host: host), hideAfter: AppActions.remoteAttachErrorSeconds)
            if openHud(id.uuidString, window: nil, spec: spec).ok {
                remoteLinkRefusalHuds[id] = hudGeneration(session: id.uuidString)
                return
            }
        }
        let player = statusSoundPlayer
        Task { await player.play("default") }
    }

    /// showsRemoteLinkRefusal says whether `id`'s live HUD is still the refusal panel a forwarded click opened, which a
    /// mirrored HUD replaces rather than waiting behind; a newer HUD in the slot has another generation.
    func showsRemoteLinkRefusal(_ id: UUID) -> Bool {
        guard let generation = remoteLinkRefusalHuds[id] else { return false }
        if hudGeneration(session: id.uuidString) == generation { return true }
        remoteLinkRefusalHuds[id] = nil
        return false
    }

    /// remoteLinkPageHidden says whether this Mac would hide a page or panel over `id`: a HUD already up, which a new
    /// one would replace, a cover overlay, or a zoomed terminal in its window.
    private func remoteLinkPageHidden(_ id: UUID) -> Bool {
        guard let session = library.store(forSession: id)?.session(withID: id) else { return true }
        if session.hudActive || session.coverOverlayVisible { return true }
        guard let windowID = library.windowID(forSession: id) else { return false }
        return TerminalZoomRegistry.shared.controller(for: windowID)?.target != nil
    }
}
