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
        scheduleTreeChanged()
    }

    func emitSessionClosed(_ session: Session, workspace: UUID) {
        emitControlEvent(.sessionClosed, workspace: workspace, session: session.id,
                         payload: ControlEventPayload(name: session.displayName))
        scheduleTreeChanged()
    }

    /// Records an accepted terminal/control notification in the app event ring and returns its effective
    /// title. An unresolved session returns nil and emits nothing. Delivery gating belongs to the caller.
    @discardableResult
    public func recordNotificationEvent(forSession id: UUID, title: String, body: String) -> String? {
        guard let session = session(withID: id), let workspace = workspace(forSession: id) else { return nil }
        let effectiveTitle = title.isEmpty ? session.displayName : title
        emitControlEvent(
            .notify,
            workspace: workspace.id,
            session: id,
            payload: ControlEventPayload(name: session.displayName, title: effectiveTitle, body: body)
        )
        return effectiveTitle
    }
}
