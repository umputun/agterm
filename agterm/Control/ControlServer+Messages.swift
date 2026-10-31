import agtermCore
import Foundation

extension ControlServer {
    /// resolveMessagePane resolves the session across every open window, never the frontmost default for an
    /// id, then asks its store for the live pane.
    func resolveMessagePane(_ address: MessageAddress) -> Result<MessageRecipient, MessagePaneError> {
        let store: AppStore
        let sessionID: UUID
        switch resolver.resolveSessionTarget(address.session, window: nil) {
        case .failure(let response): return .failure(MessagePaneError(response.error ?? "no such session: \(address.session)"))
        case .success(let resolved): (store, sessionID) = resolved
        }
        guard let recipient = store.messageRecipient(session: sessionID, pane: address.pane) else {
            return .failure(MessagePaneError("pane \(address.pane.text) is not a live pane of session \(sessionID.uuidString)"))
        }
        return .success(recipient)
    }

    func messagePanes(workspace: String?, window: String?) -> Result<[MessageRecipient], MessagePaneError> {
        guard let workspace else { return .success(openStores().flatMap { $0.messageRecipients() }) }
        var panes: [MessageRecipient] = []
        let response = resolver.resolveWorkspace(workspace, window: window) { store, id in
            panes = store.messageRecipients(workspace: id)
            return ControlResponse(ok: true)
        }
        guard response.ok else { return .failure(MessagePaneError(response.error ?? "no such workspace: \(workspace)")) }
        return .success(panes)
    }

    func messageQueued(_ messageID: UUID, from: String?, to recipients: [MessageRecipient]) {
        let stores = openStores()
        for recipient in recipients {
            for store in stores where store.emitMessageQueued(messageID, from: from, to: recipient) { break }
        }
    }

    private func openStores() -> [AppStore] {
        library.openIDs().compactMap { library.store(for: $0) }
    }
}
