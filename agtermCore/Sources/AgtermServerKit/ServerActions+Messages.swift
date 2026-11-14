import agtermCore

extension ServerActions {
    public func resolveMessagePane(_ address: MessageAddress) -> Result<MessageRecipient, MessagePaneError> {
        switch resolveSession(address.session) {
        case .failure(let refusal): return .failure(MessagePaneError(refusal.response.error ?? "no such session: \(address.session)"))
        case .success(let session): return store.messagePane(session: session.id, pane: address.pane)
        }
    }

    public func messagePanes(workspace: String?, window: String?) -> Result<[MessageRecipient], MessagePaneError> {
        if let refusal = windowRefusal(window) { return .failure(MessagePaneError(refusal.error ?? "window not found")) }
        guard let workspace else { return .success(store.messageRecipients()) }
        switch resolveWorkspace(workspace) {
        case .failure(let refusal): return .failure(MessagePaneError(refusal.response.error ?? "no such workspace: \(workspace)"))
        case .success(let id): return .success(store.messageRecipients(workspace: id))
        }
    }
}
