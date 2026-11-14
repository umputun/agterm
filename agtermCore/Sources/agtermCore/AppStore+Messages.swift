import Foundation

extension AppStore {
    /// disposeMailboxes drops the bus mailbox of every pane `session` holds, scratch included. A session
    /// leaving the tree takes its mail, even through a soft close that is later undone.
    func disposeMailboxes(of session: Session) {
        disposeMailboxes([session.paneIdentity] + [session.splitPaneIdentity].compactMap { $0 })
        if let scratch = session.scratchSurface { disposeMailbox(token: scratch.paneToken) }
        if let scratch = session.scratchDaemon { MessageBus.shared.dispose(pane: scratch.identity) }
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

    /// messagePane is `messageRecipient` with the reason it fails. A remote row is refused by name: its panes live
    /// in another host's bus, which no message from this one reaches.
    public func messagePane(session sessionID: UUID, pane: MessageAddress.Pane) -> Result<MessageRecipient, MessagePaneError> {
        if session(withID: sessionID)?.remoteHost != nil {
            return .failure(MessagePaneError("session \(sessionID.uuidString) is a remote session: a local pane cannot message it",
                                             detail: "remote session"))
        }
        guard let recipient = messageRecipient(session: sessionID, pane: pane) else {
            return .failure(MessagePaneError("pane \(pane.text) is not a live pane of session \(sessionID.uuidString)"))
        }
        return .success(recipient)
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
        guard let session = session(holdingPane: recipient.pane) else { return false }
        emitMessageEvent(session, pane: recipient.pane, from: from, messageID: messageID)
        return true
    }

    /// publishMessageQueued hands a queued message to every viewer of the session holding the recipient's pane.
    public func publishMessageQueued(_ messageID: UUID, from: String?, to recipient: MessageRecipient) {
        guard let session = session(holdingPane: recipient.pane) else { return }
        presentationHub?.publish(.message(PresentationMessage(pane: recipient.pane, from: from, messageID: messageID)),
                                 session: session.id)
    }

    /// emitRemoteMessage emits the `message` event for mail the row's server queued; the pane is the server's.
    public func emitRemoteMessage(_ message: PresentationMessage, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        emitMessageEvent(session, pane: message.pane, from: message.from, messageID: message.messageID)
    }

    private func emitMessageEvent(_ session: Session, pane: UUID, from: String?, messageID: UUID) {
        emitControlEvent(.message, workspace: workspace(forSession: session.id)?.id, session: session.id,
                         payload: ControlEventPayload(name: session.displayName, paneID: pane.uuidString,
                                                      from: from, messageID: messageID.uuidString))
    }

    private func session(holdingPane pane: UUID) -> Session? {
        workspaces.flatMap(\.sessions).first { livePanes(of: $0).contains { $0.pane == pane } }
    }

    /// applyCatalogMail keeps a remote window row's mail counts on what its server's catalog lists.
    func applyCatalogMail(_ session: Session, entry: CatalogSession) {
        let panes = entry.panes + [entry.fields.scratch?.pane].compactMap { $0 }
        session.catalogMail = Dictionary(panes.compactMap { pane in pane.pendingMessages.map { (pane.identity, $0) } }) { $1 }
    }

    /// livePanes are the session's panes a message can reach: a realized surface carrying a pane token, or on a
    /// headless store, which has no surfaces, a pane whose daemon it owns.
    private func livePanes(of session: Session) -> [(role: StatusPane, pane: UUID)] {
        if headless {
            let roles: [(StatusPane, CommandContext.Pane)] = [(.left, .left), (.right, .right), (.scratch, .scratch)]
            return roles.compactMap { role, pane in UUID(uuidString: session.paneToken(for: pane)).map { (role, $0) } }
        }
        let slots: [(StatusPane, (any TerminalSurface)?)] = [
            (.left, session.surface), (.right, session.splitSurface), (.scratch, session.scratchSurface),
        ]
        return slots.compactMap { role, surface in
            guard let surface, surface.isRealized, let pane = UUID(uuidString: surface.paneToken) else { return nil }
            return (role, pane)
        }
    }

    /// pendingMessages is the tree read-back for one of `session`'s panes: a remote row's from its server's catalog,
    /// a local pane's from this bus; nil at zero.
    func pendingMessages(_ session: Session, pane: UUID?, token: String?) -> Int? {
        guard session.remoteHost != nil else { return pendingMessages(token: token) }
        return pane.flatMap { session.catalogMail[$0] }
    }

    /// scratchPendingMessages is the tree read-back for a server scratch's mail, on the server and on a viewing Mac.
    func scratchPendingMessages(_ session: Session) -> Int? {
        let scratch = session.scratchDaemon?.identity
        return pendingMessages(session, pane: scratch, token: scratch?.uuidString)
    }

    /// pendingMessages is the unacked count of the pane a token names, nil at zero.
    func pendingMessages(token: String?) -> Int? {
        guard let pane = token.flatMap(UUID.init(uuidString:)) else { return nil }
        let count = MessageBus.shared.pending(for: pane)
        return count > 0 ? count : nil
    }
}
