import Foundation
import agtermCore

extension ServerActions: CatalogOperationHost {
    public var takesOperationReceipts: Bool { true }

    public var operationStore: AppStore { store }
    public var operationHub: CatalogHub { streams.catalogHub }

    /// operationRefusal refuses what a page row cannot take and an operation decided on panes or a scratch the
    /// target no longer has.
    public func operationRefusal(_ request: ControlRequest) -> String? {
        pageRowRefusal(request)?.error
            ?? request.args?.panes.flatMap { paneRefusal(request.target, expected: $0) }
            ?? request.args?.scratch.flatMap { scratchRefusal(request.target, expected: $0) }
    }

    public func runOperation(_ request: ControlRequest) async -> ControlResponse {
        await ControlDispatcher(actions: self).dispatch(request)
            ?? ControlResponse(ok: false, error: "\(request.cmd.rawValue) is not available on agterm-server")
    }

    public func catalogOperation(_ opID: String, sent: CatalogPosition?, window: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        return operationBook.lookup(opID, sent: sent, host: self)
    }

    /// paneRefusal refuses an operation decided on panes `target` no longer has, resolving it as the command does;
    /// a target that resolves to no session is left to the command's own error.
    private func paneRefusal(_ target: String?, expected: [String]) -> String? {
        guard case .success(let session) = resolveSession(target) else { return nil }
        // a page row's catalog entry lists no pane
        var current = session.content == .page ? [] : [session.paneIdentity.uuidString]
        if session.hasSplit, let split = session.splitPaneIdentity { current.append(split.uuidString) }
        return current == expected.map { $0.uppercased() } ? nil : "the session's panes changed; take the catalog again"
    }
}
