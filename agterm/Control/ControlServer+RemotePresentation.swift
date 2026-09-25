import Foundation
import os
import agtermCore

private let remoteLogger = Logger(subsystem: "com.umputun.agterm", category: "RemotePresentation")

/// The viewer's side of a mirrored HUD: the origin's panel shown through this app's own HUD path, so it is
/// sized to this Mac's pane, painted by the bundled helper, and comes down on this Mac's own timer.
extension ControlServer {
    /// Opens `session`'s presentation stream to its origin. A session that is not attached, or whose stream
    /// is already up, is left alone; a failure here never touches the terminal attach.
    func startRemotePresentation(for session: Session) {
        let id = session.id
        guard remoteClients[id] == nil, let host = session.remoteHost,
              let binding = session.remotePresentation?.binding else { return }
        let argv: [String]
        do {
            argv = try RemoteSession.presentCommand(host: host, session: binding.remoteSessionID)
        } catch {
            remoteLogger.error("no presentation stream for \(id, privacy: .public): the origin's session id cannot be sent")
            return
        }
        let client = RemotePresentationClient(argv: argv, presentationVersion: binding.presentationVersion,
                                              transport: remoteTransport, effects: remoteEffects(for: id),
                                              now: hudClock)
        remoteClients[id] = client
        client.start()
        startRemoteTick()
    }

    func stopRemotePresentation(_ id: UUID) {
        remoteClients.removeValue(forKey: id)?.stop()
    }

    func stopRemotePresentations() {
        for client in remoteClients.values { client.stop() }
        remoteClients.removeAll()
        remoteTick?.cancel()
        remoteTick = nil
    }

    /// A soft close hides the row while its panes live on for undo, and undo or a restored workspace brings
    /// it back without passing through the attach, so the client follows the row and not the attach.
    func remoteRowVisibilityChanged(_ session: Session, shown: Bool) {
        if shown {
            startRemotePresentation(for: session)
        } else {
            stopRemotePresentation(session.id)
        }
    }

    private func remoteEffects(for id: UUID) -> RemotePresentationEffects {
        RemotePresentationEffects(
            status: { [weak self] status in
                self?.library.store(forSession: id)?.applyRemoteStatus(status, forSession: id)
            },
            snapshotStatus: { [weak self] status in
                self?.library.store(forSession: id)?.applyRemoteSnapshotStatus(status, forSession: id)
            },
            hud: { [weak self] hud in self?.showRemoteHud(hud, forSession: id) },
            notify: { [weak self] notify in
                guard let session = self?.library.store(forSession: id)?.session(withID: id) else { return }
                // `.mirrored`, so this Mac's own hub never relays it onward
                NotificationManager.shared.send(toSession: session, title: notify.title, body: notify.body,
                                                origin: .mirrored)
            },
            connection: { [weak self] connection in
                self?.library.store(forSession: id)?.setRemoteConnection(connection, forSession: id)
            },
            context: { [weak self] context in
                self?.library.store(forSession: id)?.applyRemoteContext(context, forSession: id)
            },
            mode: { [weak self] mode in self?.library.store(forSession: id)?.setRemoteMode(mode, forSession: id) },
            askRequest: { [weak self] ask in self?.showReplicaAsk(ask, forSession: id) ?? false },
            askDismiss: { [weak self] ref in self?.library.store(forSession: id)?.dismissReplicaAsk(ref, forSession: id) },
            overlayRequest: { [weak self] overlay in self?.showReplicaOverlay(overlay, forSession: id) ?? false },
            overlayClose: { [weak self] change in
                self?.library.store(forSession: id)?.closeReplicaOverlay(change.job, forSession: id)
            },
            overlayResize: { [weak self] change in
                self?.library.store(forSession: id)?.resizeReplicaOverlay(change, forSession: id)
            },
            layout: { [weak self] layout in
                guard let self, let store = library.store(forSession: id) else { return }
                agtermApp.applyRemoteLayout(layout, store: store, sessionID: id, library: library)
            },
            warn: { reason in
                remoteLogger.warning("presentation stream for \(id, privacy: .public): \(reason, privacy: .public)")
            })
    }

    /// Shows an ask `id`'s origin handed over. A GUI one keeps the local rule of refusing a target that is not
    /// on screen; a terminal one, like a local terminal ask, waits hidden until its session is shown.
    private func showReplicaAsk(_ ask: PresentationAsk, forSession id: UUID) -> Bool {
        guard let store = library.store(forSession: id) else { return false }
        if ask.style == .gui {
            guard let windowID = library.windowID(for: store), guiTargetShown(id, in: store, windowID: windowID) else {
                return false
            }
        }
        return store.presentReplicaAsk(ask, forSession: id) { [weak self] body in self?.remoteClients[id]?.answer(body) }
    }

    /// Shows an overlay `id`'s origin handed over, running the job's helper on the origin over ssh.
    private func showReplicaOverlay(_ overlay: PresentationOverlay, forSession id: UUID) -> Bool {
        guard let store = library.store(forSession: id), let host = store.session(withID: id)?.remoteHost,
              let argv = try? RemoteSession.runJobCommand(host: host, job: overlay.job) else { return false }
        let command = CommandRestore.shellQuotedLine(argv)
        return store.presentReplicaOverlay(overlay, command: command, forSession: id) { [weak self] job in
            self?.remoteClients[id]?.answer(.overlayClosed(PresentationOverlayChange(job: job)))
        }
    }

    func startRemoteTick() {
        guard remoteTick == nil else { return }
        remoteTick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard !self.remoteClients.isEmpty || !RemoteReconnectBook.shared.isEmpty else {
                    self.remoteTick = nil
                    return
                }
                for client in self.remoteClients.values { client.tick() }
                self.tickReconnects()
            }
        }
    }

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
                           hideAfter: hud.remaining, markdown: hud.spec.markdown, fontSize: hud.spec.fontSize)
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
