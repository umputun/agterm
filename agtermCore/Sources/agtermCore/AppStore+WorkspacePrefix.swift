import Foundation

public enum WorkspacePrefixOutcome: Equatable, Sendable {
    case workspace(UUID)
    case none
    case ambiguous([String])
    case unavailable

    /// The `workspace.go --prefix` refusal, nil for a match; host-free so every host words it alike.
    public func controlError(prefix: String) -> String? {
        switch self {
        case .workspace: return nil
        case .none: return "no workspace matches prefix: \(prefix)"
        case .ambiguous(let names): return "prefix \(prefix) matches several workspaces: \(names.joined(separator: ", "))"
        case .unavailable: return "workspace.go --prefix needs the tree view, not flagged"
        }
    }
}

extension AppStore {
    /// Resolves `prefix` against `visibleWorkspaces`, the scope `navigateWorkspace` steps, so a focus filter
    /// confines it the same way. Unavailable in flagged mode for `canStepWorkspaces`'s reason.
    public func resolveWorkspacePrefix(_ prefix: String) -> WorkspacePrefixOutcome {
        guard sidebarMode == .tree else { return .unavailable }
        let candidates = visibleWorkspaces
        switch WorkspacePrefix.resolve(prefix, in: candidates.map(\.name)) {
        case .match(let index): return .workspace(candidates[index].id)
        case .none: return .none
        case .ambiguous(let indices): return .ambiguous(indices.map { candidates[$0].name })
        }
    }
}
