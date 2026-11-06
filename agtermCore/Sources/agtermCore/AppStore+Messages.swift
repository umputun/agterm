import Foundation

extension AppStore {
    /// disposeMailboxes drops the bus mailbox of every pane `session` holds, scratch included. A session
    /// leaving the tree takes its mail, even through a soft close that is later undone.
    func disposeMailboxes(of session: Session) {
        disposeMailboxes([session.paneIdentity] + [session.splitPaneIdentity].compactMap { $0 })
        if let scratch = session.scratchSurface { disposeMailbox(token: scratch.paneToken) }
    }

    func disposeMailboxes(_ panes: [UUID]) {
        panes.forEach { MessageBus.shared.dispose(pane: $0) }
    }

    /// disposeMailbox drops the mailbox keyed by a surface's pane token, the scratch pane's only identity.
    func disposeMailbox(token: String) {
        if let pane = UUID(uuidString: token) { MessageBus.shared.dispose(pane: pane) }
    }

    /// messageRecipient resolves one pane of `sessionID` to a live pane: a role picks that slot's surface now,
    /// a pane id must be one of the session's own live panes. Nil for a remote session or no such live pane.
    public func messageRecipient(session sessionID: UUID, pane: MessageAddress.Pane) -> MessageRecipient? {
        guard let session = session(withID: sessionID), session.remoteHost == nil else { return nil }
        let live = livePanes(of: session)
        let found: UUID? = switch pane {
        case .role(let role): live.first { $0.role == role }?.pane
        case .id(let id): live.first { $0.pane == id }?.pane
        }
        return found.map { MessageRecipient(pane: $0, address: MessageAddress.canonical(session: session.id, pane: $0)) }
    }

    /// messageRecipients lists every live pane of this store's local sessions, or of one workspace's.
    public func messageRecipients(workspace: UUID? = nil) -> [MessageRecipient] {
        workspaces.filter { workspace == nil || $0.id == workspace }.flatMap(\.sessions)
            .filter { $0.remoteHost == nil }
            .flatMap { session in
                livePanes(of: session).map {
                    MessageRecipient(pane: $0.pane, address: MessageAddress.canonical(session: session.id, pane: $0.pane))
                }
            }
    }

    /// emitMessageQueued emits the `message` event when this store holds the recipient's pane.
    @discardableResult
    public func emitMessageQueued(_ messageID: UUID, from: String?, to recipient: MessageRecipient) -> Bool {
        let sessions = workspaces.flatMap(\.sessions)
        guard let session = sessions.first(where: { livePanes(of: $0).contains { $0.pane == recipient.pane } }) else {
            return false
        }
        emitControlEvent(.message, workspace: workspace(forSession: session.id)?.id, session: session.id,
                         payload: ControlEventPayload(name: session.displayName, paneID: recipient.pane.uuidString,
                                                      from: from, messageID: messageID.uuidString))
        return true
    }

    /// livePanes are the session's panes a message can reach: a realized surface carrying a pane token.
    private func livePanes(of session: Session) -> [(role: StatusPane, pane: UUID)] {
        let slots: [(StatusPane, (any TerminalSurface)?)] = [
            (.left, session.surface), (.right, session.splitSurface), (.scratch, session.scratchSurface),
        ]
        return slots.compactMap { role, surface in
            guard let surface, surface.isRealized, let pane = UUID(uuidString: surface.paneToken) else { return nil }
            return (role, pane)
        }
    }

    /// pendingMessages is the tree read-back for a pane token: its unacked count, nil at zero.
    func pendingMessages(token: String?) -> Int? {
        guard let pane = token.flatMap(UUID.init(uuidString:)) else { return nil }
        let count = MessageBus.shared.pending(for: pane)
        return count > 0 ? count : nil
    }
}
