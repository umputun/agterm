import Foundation

// MARK: - Ask draft, answers and cancellation

extension Session {
    /// The anchored pane's current role, nil for session-wide placement or a destroyed pane.
    public var askTargetPane: OverlayPane? {
        askPaneIdentity.flatMap(paneRole(forIdentity:))
    }

    /// Edits the pending ask's draft; a stale id, from a dialog already resolved, changes nothing.
    public func updateAskDraft(id: String, _ change: (inout AskDraft) -> Void) {
        guard askPending?.id == id, var draft = askDraft else { return }
        change(&draft)
        askDraft = draft
    }

    /// Answers the pending ask with the button at `index` and the current draft.
    @discardableResult
    public func answerAsk(id: String, buttonAt index: Int) -> Bool {
        guard let ask = askPending, ask.id == id, let result = ask.answer(buttonAt: index, draft: askDraft) else {
            return false
        }
        return resolveAsk(id: id, result)
    }

    /// Cancels the current ask only when its id matches.
    @discardableResult
    public func cancelAsk(id: String) -> Bool {
        resolveAsk(id: id, ControlAskResult(result: .cancelled))
    }

    /// Cancels the session's pending ask, if any.
    public func cancelPendingAsk() { if let ask = askPending { cancelAsk(id: ask.id) } }
}
