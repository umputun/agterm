import Foundation

// MARK: - Root container

extension Workspace {
    /// The name a user reads for this container: `ControlWorkspaceNode.rootLabel` for the root, else `name`.
    public var label: String { isRoot ? ControlWorkspaceNode.rootLabel : name }
}

/// A window's top-level sessions live in one implicit root `Workspace`. It is stored LAST, so every named index
/// (`workspace.move`, Recent Closed placement, catalog positions) keeps its meaning, and displayed FIRST.
/// Only a store that owns its tree has one: the load boundary calls `ensureRoot()`, while a remote window
/// adopts its origin's root and a store built directly has none.
extension AppStore {
    /// The root container; nil for a store that has not been given one.
    public var rootWorkspace: Workspace? { workspaces.first { $0.isRoot } }

    /// Every workspace but the root.
    public var namedWorkspaces: [Workspace] { workspaces.filter { !$0.isRoot } }

    /// The sidebar's order: the root, then the named workspaces.
    public var displayWorkspaces: [Workspace] {
        guard let root = rootWorkspace else { return workspaces }
        return [root] + namedWorkspaces
    }

    func namedWorkspaceIndex(of id: UUID) -> Int? {
        workspaces.firstIndex { $0.id == id && !$0.isRoot }
    }

    /// Where a named workspace is inserted to land after every other one.
    var namedEndIndex: Int { workspaces.firstIndex(where: \.isRoot) ?? workspaces.count }

    /// Whether new sessions land in the root.
    public var isCurrentWorkspaceRoot: Bool {
        guard let current = currentWorkspaceID else { return false }
        return current == rootWorkspace?.id
    }

    /// rootRefusal answers a workspace-only command (rename, tint, delete, move, collapse, expand, select, detach)
    /// that resolved to the root; nil for a named workspace.
    public func rootRefusal(_ id: UUID) -> ControlResponse? {
        guard rootWorkspace?.id == id else { return nil }
        return ControlResponse(ok: false, error: "top-level sessions are not a workspace")
    }

    /// Mints an empty root when there is none and stores it last. Returns whether the tree changed, so the load
    /// boundary knows to persist a minted id. A second root in a snapshot is folded by `restore(from:)`.
    @discardableResult
    public func ensureRoot() -> Bool {
        guard let index = workspaces.firstIndex(where: \.isRoot) else {
            workspaces.append(Workspace(name: "", isRoot: true))
            return true
        }
        guard index != workspaces.count - 1 else { return false }
        workspaces.append(workspaces.remove(at: index))
        return true
    }

    /// workspaceStep is the one server move step that takes a named workspace to `destination` among the named
    /// workspaces, nil when no single step lands it or `id` is not a named workspace.
    public func workspaceStep(moving id: UUID, to destination: Int) -> String? {
        guard let source = namedWorkspaceIndex(of: id) else { return nil }
        return RemoteOperation.workspaceStep(from: source, to: destination, count: namedWorkspaces.count)
    }
}
