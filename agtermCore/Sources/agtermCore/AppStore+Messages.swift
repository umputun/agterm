import Foundation

extension AppStore {
    /// disposeMailboxes drops the bus mailbox of every pane `session` holds, scratch included. A session
    /// leaving the tree takes its mail, even through a soft close that is later undone.
    func disposeMailboxes(of session: Session) {
        disposeMailboxes([session.paneIdentity] + [session.splitPaneIdentity].compactMap { $0 })
        if let scratch = session.scratchSurface { disposeMailbox(token: scratch.paneToken) }
        if let scratch = session.scratchDaemon { disposeMailboxes([scratch.identity]) }
    }

    /// disposeMailboxes drops each pane's mailbox with its daemon generation record.
    func disposeMailboxes(_ panes: [UUID]) {
        panes.forEach {
            MessageBus.shared.dispose(pane: $0)
            daemonGenerations[$0] = nil
        }
    }

    /// daemonKilled drops the mail of a pane whose daemon a confirmed kill ended while no surface showed it; a pane
    /// with a surface loses its mail through that surface's exit instead.
    public func daemonKilled(_ pane: UUID) {
        disposeMailboxes([pane])
    }

    /// disposeMailbox drops the mailbox keyed by a surface's pane token, the scratch pane's only identity.
    func disposeMailbox(token: String) {
        if let pane = UUID(uuidString: token) { disposeMailboxes([pane]) }
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
        guard let session = session(holding: recipient) else { return false }
        emitMessageEvent(session, pane: recipient.pane, from: from, messageID: messageID)
        return true
    }

    /// publishMessageQueued hands a queued message to every viewer of the session holding the recipient's pane.
    public func publishMessageQueued(_ messageID: UUID, from: String?, to recipient: MessageRecipient) {
        guard let session = session(holding: recipient) else { return }
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

    // read from the canonical address the recipient was resolved with, never by probing panes again: the mail is
    // already queued, and a generation check here could drop the message it reports
    private func session(holding recipient: MessageRecipient) -> Session? {
        guard let id = recipient.address.split(separator: ":").first.flatMap({ UUID(uuidString: String($0)) }),
              let session = session(withID: id) else { return nil }
        let tokens = [session.surface, session.splitSurface, session.scratchSurface].compactMap { $0.flatMap { UUID(uuidString: $0.paneToken) } }
        return (session.locallyManagedPaneIdentities + tokens).contains(recipient.pane) ? session : nil
    }

    /// applyCatalogPanes keeps a remote window row's panes, their mail counts and held state, on what its server's
    /// catalog lists.
    func applyCatalogPanes(_ session: Session, entry: CatalogSession) {
        let panes = entry.panes + [entry.fields.scratch?.pane].compactMap { $0 }
        session.catalogPanes = Dictionary(panes.map { ($0.identity, $0) }) { $1 }
    }

    /// livePanes are the session's panes a message can reach: a realized surface carrying a pane token, a local Live
    /// pane with no realized surface whose daemon runs, or on a headless store, which has no surfaces, a pane whose
    /// daemon it owns.
    func livePanes(of session: Session) -> [(role: StatusPane, pane: UUID)] {
        if headless {
            let roles: [(StatusPane, CommandContext.Pane)] = [(.left, .left), (.right, .right), (.scratch, .scratch)]
            return roles.compactMap { role, pane in UUID(uuidString: session.paneToken(for: pane)).map { (role, $0) } }
        }
        let owned = session.locallyManagedPaneIdentities
        let slots: [(StatusPane, (any TerminalSurface)?, UUID?)] = [
            (.left, session.surface, session.paneIdentity), (.right, session.splitSurface, session.splitPaneIdentity),
            (.scratch, session.scratchSurface, session.localScratchIdentity),
        ]
        return slots.compactMap { role, surface, daemon in
            let realized = surface.flatMap { $0.isRealized ? UUID(uuidString: $0.paneToken) : nil }
            guard let daemon, owned.contains(daemon), realized == nil || daemonGenerations[daemon] != nil else {
                return realized.map { (role, $0) }
            }
            if let surface, realized != nil, !surface.backedByZmx {
                disposeMailboxes([daemon])
                return realized.map { (role, $0) }
            }
            return daemonRuns(daemon) ? (role, daemon) : nil
        }
    }

    // the record outlives the surface's realization: its attach may still replace the daemon under the same identity,
    // so a pane keeps the mail only while the leader is the one it was queued for. An absent daemon took its mail with
    // it, but the record stays so a realized view keeps being probed; an unknown one refuses mail and drops none.
    private func daemonRuns(_ pane: UUID) -> Bool {
        let probe = daemonProbe?(pane)
        if probe == .absent, daemonGenerations[pane] != nil { MessageBus.shared.dispose(pane: pane) }
        guard case .running(let leader) = probe else { return false }
        if let recorded = daemonGenerations[pane], recorded != leader { MessageBus.shared.dispose(pane: pane) }
        daemonGenerations[pane] = leader
        return true
    }

    /// pendingMessages is the tree read-back for one of `session`'s panes, nil at zero: a local pane's from this bus,
    /// a remote window row's from its server's catalog, any other attached row's from its presentation stream,
    /// mapped to the origin's pane. The two remote sources never share a cache, so neither overwrites the other.
    func pendingMessages(_ session: Session, pane: UUID?, token: String?) -> Int? {
        guard session.remoteHost != nil else { return pendingMessages(token: token) }
        guard let pane else { return nil }
        guard let state = session.remotePresentation, !state.binding.catalogOwned else { return session.catalogPanes[pane]?.pendingMessages }
        let scratch = pane == session.scratchClientIdentity || pane == session.originScratch
        let origin = scratch ? session.originScratch : state.binding.remotePane(forLocal: pane)
        return origin.flatMap { state.mail?.panes[$0.uuidString] }
    }

    /// scratchPendingMessages is the tree read-back for a server scratch's mail, on the server and on a viewing Mac.
    func scratchPendingMessages(_ session: Session) -> Int? {
        let scratch = session.scratchDaemon?.identity
        return pendingMessages(session, pane: scratch, token: scratch?.uuidString)
    }

    /// presentationMail is the unacked mail of `id`'s main, split and scratch panes for its viewers, keyed by the
    /// identities its layout names. Nil for a session this store does not host: a remote row's mail is its host's.
    func presentationMail(forSession id: UUID) -> PresentationMail? {
        guard let session = session(withID: id), session.remoteHost == nil, session.content == .terminal else { return nil }
        let counts = session.locallyManagedPaneIdentities.compactMap { pane -> (String, Int)? in
            let count = MessageBus.shared.pending(for: pane)
            return count > 0 ? (pane.uuidString, count) : nil
        }
        return PresentationMail(panes: Dictionary(counts) { $1 })
    }

    /// publishPresentationMail hands `id`'s current mail counts to the hub, which sends them only to viewers whose
    /// last counts differ.
    public func publishPresentationMail(forSession id: UUID) {
        guard let hub = presentationHub, let mail = presentationMail(forSession: id) else { return }
        hub.publishMail(mail, session: id)
    }

    /// pendingMessages is the unacked count of the pane a token names, nil at zero.
    func pendingMessages(token: String?) -> Int? {
        guard let pane = token.flatMap(UUID.init(uuidString:)) else { return nil }
        let count = MessageBus.shared.pending(for: pane)
        return count > 0 ? count : nil
    }
}
