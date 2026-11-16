import Foundation

/// OriginCatalogScope holds a remote window's operation to the one Mac window it names: every row and workspace the
/// request reaches must be that window's, by full id, and a row attached from another host, which the catalog does not
/// show, is never a target or an anchor. Undo ids and Recent Closed entries are scoped by their own commands.
@MainActor
public enum OriginCatalogScope {
    static let unscoped: Set<Command> = [.sessionUndo, .recentOpen, .workspaceNew]
    static let workspaceTargeted: Set<Command> = [.workspaceRename, .workspaceDelete, .workspaceMove, .workspaceFlag, .workspaceTint]

    /// refusal answers why `request` reaches outside `store`, nil when it stays inside.
    public static func refusal(_ request: ControlRequest, in store: AppStore) -> String? {
        guard !unscoped.contains(request.cmd) else { return nil }
        let args = request.args ?? ControlArgs()
        // an omitted target resolves the origin's own selection, which can be a row the catalog does not show
        let rowless = request.cmd == .sessionNew || (request.cmd == .sessionFlag && args.mode == "clear")
        if request.target == nil, !rowless { return "\(request.cmd.rawValue) from a remote window names its target" }
        if workspaceTargeted.contains(request.cmd), let target = request.target {
            return workspaceRefusal(target, in: store) ?? deleteRefusal(request, target: target, in: store)
        }
        let rows = [request.target].compactMap { $0 } + (args.targets ?? []) + [args.after, args.before].compactMap { $0 }
        for row in rows {
            if let refusal = sessionRefusal(row, in: store) { return refusal }
        }
        return args.workspace.flatMap { workspaceRefusal($0, in: store) }
    }

    private static func sessionRefusal(_ reference: String, in store: AppStore) -> String? {
        guard let session = UUID(uuidString: reference).flatMap(store.session(withID:)) else {
            return "no session \(reference) in this window"
        }
        guard let host = session.remoteHost else { return nil }
        return "session \(reference) is attached from \(host) and is not part of this window's catalog"
    }

    private static func workspaceRefusal(_ reference: String, in store: AppStore) -> String? {
        let id = UUID(uuidString: reference)
        return store.workspaces.contains { $0.id == id } ? nil : "no workspace \(reference) in this window"
    }

    private static func deleteRefusal(_ request: ControlRequest, target: String, in store: AppStore) -> String? {
        guard request.cmd == .workspaceDelete,
              let workspace = store.workspaces.first(where: { $0.id == UUID(uuidString: target) }) else { return nil }
        let hidden = workspace.sessions.filter { $0.remoteHost != nil }.count
        guard hidden > 0 else { return nil }
        let rows = hidden == 1 ? "1 session" : "\(hidden) sessions"
        return "workspace \(workspace.name) holds \(rows) attached from other hosts, which a remote window does not show; delete it on this Mac"
    }
}
