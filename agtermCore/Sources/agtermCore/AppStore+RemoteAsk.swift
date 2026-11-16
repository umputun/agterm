import Foundation

// MARK: - Asks handed to the viewer presenting a session, on the origin

extension AppStore {
    /// Hands a session-associated ask to the viewer leading its pane when the target follows remotely.
    /// Nil leaves it local; false means the session's ask slot is taken.
    ///
    /// The ask keeps the session's slot and its result on this Mac, marked as presented elsewhere, so every
    /// cancel and teardown path that already ends an ask here ends this one too and tells the presenter.
    public func presentAskRemotely(_ ask: PendingAsk, in session: Session, paneIdentity: UUID?,
                                   window: WindowInfo.ID) -> Bool? {
        switch openRemoteAsk(ask, in: session, paneIdentity: paneIdentity, window: window) {
        case .opened: true
        case .slotTaken: false
        case .notPresented, .formUnsupported, .otherUnsupported, .tooLarge: nil
        }
    }

    /// openRemoteAsk is `presentAskRemotely` with the reason an ask stayed unsent, for a host that cannot draw it
    /// locally and has to tell its caller why.
    public func openRemoteAsk(_ ask: PendingAsk, in session: Session, paneIdentity: UUID?,
                              window: WindowInfo.ID) -> RemoteAskOpening {
        // an expired ask is never shown: the caller holds it and its deadline ends it
        guard let hub = presentationHub, !ask.expired(at: Date()),
              let owner = remoteRecipient(session, paneIdentity: paneIdentity) else { return .notPresented }
        let request = PresentationAsk(ask, pane: paneIdentity.map { .identity($0) }, owner: owner, offer: hub.newOffer(toOwner: owner))
        if let refusal = askOfferRefusal(request, hub: hub) { return refusal }
        guard session.openAsk(ask, paneIdentity: paneIdentity, remoteOwner: owner, registry: askRegistry) else { return .slotTaken }
        askRegistry.register(id: ask.id, owner: .session(session.id, window: window))
        handOver(request, in: session, hub: hub)
        return .opened
    }

    /// openUnpresentedAsk books an ask a headless origin holds until a presenter can show it. False when the
    /// session's ask slot is taken.
    public func openUnpresentedAsk(_ ask: PendingAsk, in session: Session, paneIdentity: UUID?, window: WindowInfo.ID) -> Bool {
        guard session.openAsk(ask, paneIdentity: paneIdentity, registry: askRegistry) else { return false }
        askRegistry.register(id: ask.id, owner: .session(session.id, window: window))
        return true
    }

    /// offerPendingAsk hands `id`'s unpresented ask to the viewer its pane routes to; false when there is none, or that
    /// viewer cannot show it and it stays unpresented.
    @discardableResult
    public func offerPendingAsk(forSession id: UUID) -> Bool {
        guard let session = session(withID: id),
              let owner = pendingRecipient(session, paneIdentity: session.askPaneIdentity) else { return false }
        return offerAsk(forSession: id, to: owner)
    }

    /// offerAsk hands `id`'s ask in its session slot, drawn here or held unpresented, to viewer `owner`; false when there
    /// is none, or that viewer cannot show it and the ask stays where it is.
    @discardableResult
    public func offerAsk(forSession id: UUID, to owner: Int) -> Bool {
        guard let hub = presentationHub, let session = session(withID: id), let ask = session.askPending,
              !session.askPresentedRemotely, !session.askReplica, takesHeldWork(owner), mayHandOver(ask.id, to: owner) else { return false }
        let request = PresentationAsk(ask, pane: session.askPaneIdentity.map { .identity($0) }, owner: owner,
                                      offer: hub.newOffer(toOwner: owner))
        guard askOfferRefusal(request, hub: hub) == nil else { return false }
        session.askRemoteOwner = request.owner
        session.askDraft = AskDraft(form: ask.form)
        handOver(request, in: session, hub: hub)
        return true
    }

    /// moveRemoteAsk hands `id`'s ask from the viewer presenting it to viewer `owner`, then takes the old copy down;
    /// false when that viewer cannot show it, and the ask stays with its presenter.
    @discardableResult
    public func moveRemoteAsk(forSession id: UUID, to owner: Int) -> Bool {
        guard let hub = presentationHub, let session = session(withID: id), let ask = session.askPending,
              let previous = session.askRemoteOwner, previous != owner, takesHeldWork(owner), mayHandOver(ask.id, to: owner)
        else { return false }
        let request = PresentationAsk(ask, pane: session.askPaneIdentity.map { .identity($0) }, owner: owner,
                                      offer: hub.newOffer(toOwner: owner))
        guard askOfferRefusal(request, hub: hub) == nil else { return false }
        // the new owner is recorded before either send, so a viewer a stalled send drops finds nothing it owns
        session.askRemoteOwner = owner
        noteGivenUp(ask.id, by: previous)
        handOver(request, in: session, hub: hub)
        hub.send(.askDismiss(PresentationAskRef(id: ask.id, owner: previous)), toOwner: previous)
        return true
    }

    /// handGuiAskToViewer moves the GUI ask `controller` shows for session `id` into the session's slot, handed to viewer
    /// `owner`; false when the slot is taken or that viewer cannot show it, and the ask stays in its window.
    public func handGuiAskToViewer(_ controller: PickController, window: WindowInfo.ID, forSession id: UUID, to owner: Int) -> Bool {
        guard let hub = presentationHub, let session = session(withID: id), session.askPending == nil,
              let shown = controller.pendingAsk, shown.anchor?.sessionID == id, !shown.expired(at: Date()),
              takesHeldWork(owner), mayHandOver(shown.id, to: owner) else { return false }
        let identity = shown.anchor?.paneIdentity
        let ask = shown.anchored(at: nil)
        let request = PresentationAsk(ask, pane: identity.map { .identity($0) }, owner: owner, offer: hub.newOffer(toOwner: owner))
        guard askOfferRefusal(request, hub: hub) == nil, controller.takeAsk() != nil,
              session.openAsk(ask, paneIdentity: identity, remoteOwner: owner, registry: askRegistry) else { return false }
        askRegistry.reassign(id: ask.id, to: .session(id, window: window))
        handOver(request, in: session, hub: hub)
        return true
    }

    /// takeTerminalAskHome draws `id`'s terminal ask here again, and the viewer presenting it takes its copy down; false
    /// for a GUI ask or none.
    @discardableResult
    public func takeTerminalAskHome(forSession id: UUID) -> Bool {
        guard let session = session(withID: id), let ask = session.askPending, ask.style != .gui,
              let owner = session.askRemoteOwner else { return false }
        RemoteAskOffers.shared.forget(ask: ask.id)
        noteGivenUp(ask.id, by: owner)
        session.takeAskBack()
        presentationHub?.send(.askDismiss(PresentationAskRef(id: ask.id, owner: owner)), toOwner: owner)
        return true
    }

    /// moveGuiAskHome moves `id`'s GUI ask from the viewer presenting it into `controller`, its window's modal slot here,
    /// whose fit the host checked; false when that slot is taken, and the ask stays with its presenter.
    public func moveGuiAskHome(forSession id: UUID, into controller: PickController, window: WindowInfo.ID) -> Bool {
        guard let session = session(withID: id), let ask = session.askPending, ask.style == .gui,
              let owner = session.askRemoteOwner else { return false }
        let anchor = AskAnchor(sessionID: id, pane: session.askTargetPane, paneIdentity: session.askPaneIdentity)
        guard controller.openAsk(ask.anchored(at: anchor)) else { return false }
        RemoteAskOffers.shared.forget(ask: ask.id)
        noteGivenUp(ask.id, by: owner)
        session.releaseAsk()
        askRegistry.reassign(id: ask.id, to: .window(window))
        presentationHub?.send(.askDismiss(PresentationAskRef(id: ask.id, owner: owner)), toOwner: owner)
        return true
    }

    /// returnAskToPending takes `id`'s ask back as unpresented after the viewer `owner` it was handed to was lost or
    /// refused it; an answer from that viewer is then stale.
    public func returnAskToPending(forSession id: UUID, owner: Int) {
        guard let session = session(withID: id), session.askPresentedRemotely, session.askRemoteOwner == owner else { return }
        session.askPending.map { RemoteAskOffers.shared.forget(ask: $0.id) }
        session.askPending.map { noteGivenUp($0.id, by: owner) }
        session.takeAskBack()
    }

    private func askOfferRefusal(_ request: PresentationAsk, hub: PresentationHub) -> RemoteAskOpening? {
        if request.needsFormSupport {
            guard hub.supports(PresentationHub.askFormKind, owner: request.owner) else { return .formUnsupported }
            guard request.fitsFrames() else { return .tooLarge }
        }
        if request.needsOtherSupport, !hub.supports(PresentationHub.askOtherKind, owner: request.owner) {
            return .otherUnsupported
        }
        return nil
    }

    private func handOver(_ request: PresentationAsk, in session: Session, hub: PresentationHub) {
        RemoteAskOffers.shared.set(request.offer, ask: request.id)
        session.onRemoteAskEnded = { [weak hub, owner = request.owner] askID in
            RemoteAskOffers.shared.forget(ask: askID)
            OfferlessHolders.shared.forget(askID)
            hub?.send(.askDismiss(PresentationAskRef(id: askID, owner: owner)), toOwner: owner)
        }
        hub.send(.askRequest(request), toOwner: request.owner)
    }

    /// Applies the presenter's answer. Refused unless it is for the ask this session is presenting under that
    /// owner: a late answer after a handback, or one naming a button the ask does not have or carrying a payload
    /// its form would not produce, changes nothing.
    @discardableResult
    public func resolveRemoteAsk(_ answer: PresentationAskAnswer, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), let ask = session.askPending, ask.id == answer.id,
              session.askRemoteOwner == answer.owner, RemoteAskOffers.shared.matches(answer.offer, ask: ask.id) else { return false }
        guard let buttonID = answer.button else {
            guard answer.text == nil, answer.selected == nil else { return false }
            return session.resolveAsk(id: ask.id, ControlAskResult(result: .escaped))
        }
        guard let result = ask.validatedAnswer(buttonID: buttonID, text: answer.text, selected: answer.selected) else {
            return false
        }
        return session.resolveAsk(id: ask.id, result)
    }

    /// Whether `ref` names the ask `id` is presenting under that owner, so a refusal from a presenter that
    /// already lost it cannot take back a newer one.
    public func isPresentingRemotely(_ ref: PresentationAskRef, forSession id: UUID) -> Bool {
        guard let session = session(withID: id) else { return false }
        return session.askPending?.id == ref.id && session.askRemoteOwner == ref.owner
            && RemoteAskOffers.shared.matches(ref.offer, ask: ref.id)
    }

    /// Takes a remotely presented ask back after the viewer `owner` it was handed to was lost or refused it. A terminal
    /// ask is drawn here from now on. A GUI ask needs a window slot only the host can place, so it is returned still
    /// marked remote; the host moves it or completes it with `failHandback`.
    public func takeBackRemoteAsk(forSession id: UUID, owner: Int) -> PendingAsk? {
        guard let session = session(withID: id), let ask = session.askPending, session.askPresentedRemotely,
              session.askRemoteOwner == owner else { return nil }
        RemoteAskOffers.shared.forget(ask: ask.id)
        noteGivenUp(ask.id, by: owner)
        guard ask.style == .gui else {
            session.takeAskBack()
            return nil
        }
        return ask
    }

    /// Ends a taken-back ask this Mac cannot show: a GUI ask whose target is hidden here or whose window is
    /// holding an unrelated pick. It never waits invisibly.
    public func failHandback(forSession id: UUID) {
        guard let session = session(withID: id), let ask = session.askPending else { return }
        session.resolveAsk(id: ask.id, ControlAskResult(result: .cancelled, reason: ControlAskResult.presentationLost))
    }
}

/// RemoteAskOpening is what became of an ask handed to a viewer.
public enum RemoteAskOpening: Equatable, Sendable {
    case opened
    case slotTaken
    case notPresented
    case formUnsupported
    case otherUnsupported
    case tooLarge
}
