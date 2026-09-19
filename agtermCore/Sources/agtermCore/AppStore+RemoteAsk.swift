import Foundation

// MARK: - Asks handed to the viewer presenting a session, on the origin

extension AppStore {
    /// Hands a session-associated ask to the viewer presenting `session`. Nil when no viewer does, so the
    /// caller opens it here; false when the session's ask slot is taken.
    ///
    /// The ask keeps the session's slot and its result on this Mac, marked as presented elsewhere, so every
    /// cancel and teardown path that already ends an ask here ends this one too and tells the presenter.
    public func presentAskRemotely(_ ask: PendingAsk, in session: Session, paneIdentity: UUID?,
                                   window: WindowInfo.ID) -> Bool? {
        guard let hub = presentationHub, hub.hasPresenter(session: session.id) else { return nil }
        let owner = hub.presenterGeneration(session: session.id)
        guard session.openAsk(ask, paneIdentity: paneIdentity, remoteOwner: owner) else { return false }
        AskRegistry.shared.register(id: ask.id, owner: .session(session.id, window: window))
        session.onRemoteAskEnded = { [weak hub, id = session.id] askID in
            hub?.sendToPresenter(.askDismiss(PresentationAskRef(id: askID, owner: owner)), session: id)
        }
        let request = PresentationAsk(ask, pane: paneIdentity.map { .identity($0) }, owner: owner)
        hub.sendToPresenter(.askRequest(request), session: session.id)
        return true
    }

    /// Applies the presenter's answer. Refused unless it is for the ask this session is presenting under that
    /// owner: a late answer after a handback, or one naming a button the ask does not have, changes nothing.
    @discardableResult
    public func resolveRemoteAsk(_ answer: PresentationAskAnswer, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), let ask = session.askPending, ask.id == answer.id,
              session.askRemoteOwner == answer.owner else { return false }
        guard let buttonID = answer.button else {
            return session.resolveAsk(id: ask.id, ControlAskResult(result: .escaped))
        }
        guard let index = ask.buttons.firstIndex(where: { $0.id == buttonID }) else { return false }
        return session.resolveAsk(id: ask.id, ControlAskResult(result: .answered, id: buttonID,
                                                              label: ask.buttons[index].label, index: index))
    }

    /// Whether `ref` names the ask `id` is presenting under that owner, so a refusal from a presenter that
    /// already lost it cannot take back a newer one.
    public func isPresentingRemotely(_ ref: PresentationAskRef, forSession id: UUID) -> Bool {
        guard let session = session(withID: id) else { return false }
        return session.askPending?.id == ref.id && session.askRemoteOwner == ref.owner
    }

    /// Takes a remotely presented ask back after its presenter was lost or refused it. A terminal ask is
    /// drawn here from now on. A GUI ask needs a window slot only the host can place, so it is returned still
    /// marked remote; the host moves it or completes it with `failHandback`.
    public func takeBackRemoteAsk(forSession id: UUID) -> PendingAsk? {
        guard let session = session(withID: id), let ask = session.askPending, session.askPresentedRemotely else {
            return nil
        }
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
