import Foundation

// MARK: - Control events

extension AppStore {
    /// Emits one window-scoped draft through the app-wide ring seam. The library-owned closure adds the
    /// window id; callers supply model identities and already-normalized kind-specific payloads.
    func emitControlEvent(_ kind: ControlEventKind, workspace: UUID? = nil, session: UUID? = nil,
                          payload: ControlEventPayload = ControlEventPayload()) {
        controlEventSink?(ControlEventDraft(
            kind: kind,
            workspace: workspace?.uuidString,
            session: session?.uuidString,
            payload: payload
        ))
    }

    func scheduleTreeChanged() {
        emitControlEvent(.treeChanged)
    }

    func emitSessionCreated(_ session: Session, workspace: UUID) {
        emitControlEvent(.sessionCreated, workspace: workspace, session: session.id,
                         payload: ControlEventPayload(name: session.displayName))
        emitRemoteVisibility(.remoteOpened, session: session, workspace: workspace)
        scheduleTreeChanged()
    }

    /// `remote.opened` / `remote.closed` describe the row's visibility, undo included, never the ssh
    /// connection's state, which the app cannot observe under the hold prompt.
    private func emitRemoteVisibility(_ kind: ControlEventKind, session: Session, workspace: UUID) {
        guard let host = session.remoteHost else { return }
        emitControlEvent(kind, workspace: workspace, session: session.id,
                         payload: ControlEventPayload(name: session.displayName, host: host))
    }

    /// `pane.split` / `pane.scratch` carry `shown`/`hidden`; callers emit only on a real transition.
    func emitPaneVisibility(_ kind: ControlEventKind, session: Session, shown: Bool) {
        emitControlEvent(kind, workspace: workspace(forSession: session.id)?.id, session: session.id,
                         payload: ControlEventPayload(name: session.displayName, status: shown ? "shown" : "hidden"))
    }

    func emitSessionClosed(_ session: Session, workspace: UUID) {
        emitControlEvent(.sessionClosed, workspace: workspace, session: session.id,
                         payload: ControlEventPayload(name: session.displayName))
        emitRemoteVisibility(.remoteClosed, session: session, workspace: workspace)
        scheduleTreeChanged()
    }

    /// Records an accepted terminal/control notification in the app event ring and returns its effective
    /// title. An unresolved session returns nil and emits nothing. Delivery gating belongs to the caller.
    /// Only a `.control` one is published to attached viewers.
    @discardableResult
    public func recordNotificationEvent(forSession id: UUID, title: String, body: String,
                                        origin: NotificationOrigin = .terminal) -> String? {
        guard let session = session(withID: id), let workspace = workspace(forSession: id) else { return nil }
        let effectiveTitle = title.isEmpty ? session.displayName : title
        if origin == .control {
            presentationHub?.publish(.notify(PresentationNotify(title: effectiveTitle, body: body, pane: nil,
                                                                source: origin.rawValue)), session: id)
        }
        emitControlEvent(
            .notify,
            workspace: workspace.id,
            session: id,
            payload: ControlEventPayload(name: session.displayName, title: effectiveTitle, body: body)
        )
        return effectiveTitle
    }
}
