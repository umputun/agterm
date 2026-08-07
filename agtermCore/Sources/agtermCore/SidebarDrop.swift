import Foundation

/// SidebarDrop holds the pure index arithmetic for sidebar drag-and-drop reorder, so the trickiest part
/// (post-removal off-by-one, drop-on-row redirect, cross-workspace vs same-parent index spaces, no-op
/// detection) is host-free and table-testable. The AppKit/store glue — reading the pasteboard, resolving
/// the dragged/target ids — stays in `WorkspaceSidebar.Coordinator`, which feeds resolved indices in and
/// applies the returned destination via `AppStore`.
public enum SidebarDrop {
    /// Mirrors AppKit's `NSOutlineViewDropOnItemIndex`: a drop landing ON a row rather than between rows.
    public static let onItemIndex = -1
    /// Prevents an accidental Finder multi-selection from spawning an unbounded number of shells.
    public static let maximumDirectoryImportCount = 20

    /// Resolves the workspace for a Finder directory drop. Folder import is tree-only; a drop ON a row lands
    /// in that row's workspace, and an EMPTY-SPACE drop takes `fallbackWorkspaceID` when the caller can name
    /// an unambiguous one (`AppStore.soleFocusedWorkspaceID`: the sole marked workspace while the focus
    /// filter applies — the only state where the tree renders exactly one workspace), else the current
    /// workspace. With no marked set, the filter off, or two or more members the caller passes nil and the
    /// drop falls through to `currentWorkspaceID`.
    public static func resolveDirectoryWorkspace(sidebarMode: SidebarMode, rowWorkspaceID: UUID?,
                                                 fallbackWorkspaceID: UUID?, currentWorkspaceID: UUID?) -> UUID? {
        guard sidebarMode == .tree else { return nil }
        return rowWorkspaceID ?? fallbackWorkspaceID ?? currentWorkspaceID
    }

    /// The destination of a dragged session, or nil when the drop is a no-op (would leave order
    /// unchanged). `destination` is the POST-removal index `AppStore.moveSession` expects; `dropChildIndex`
    /// is the PRE-removal slot to highlight in the outline (or `onItemIndex` to append).
    public struct SessionResolution: Equatable, Sendable {
        public let workspace: UUID
        public let dropChildIndex: Int
        public let destination: Int
    }

    /// A dragged session's original location before a batch move removes anything.
    public struct SessionSource: Equatable, Sendable {
        public let workspace: UUID
        public let index: Int

        public init(workspace: UUID, index: Int) {
            self.workspace = workspace
            self.index = index
        }
    }

    /// Describes the row a session was dropped onto. A workspace row uses the child index directly; a
    /// session row redirects to its owner workspace, landing just after it when dropped ON the row.
    public enum SessionDropTarget: Equatable, Sendable {
        case workspaceRow(id: UUID, sessionCount: Int)
        case sessionRow(workspace: UUID, sessionIndex: Int, sessionCount: Int)
    }

    /// Resolves a session drop into the move it would perform (target workspace + post-removal index), or
    /// nil for a no-op. `childIndex` is AppKit's proposed child index (`onItemIndex` for a drop ON the
    /// target). A same-workspace DOWNWARD move subtracts 1, since the slot shifts up after the removal;
    /// cross-workspace and upward moves pass through. A same-workspace move landing the session back in its
    /// current slot (including appending an already-last session) is a no-op.
    public static func resolveSession(sourceWorkspace: UUID, sourceIndex: Int,
                                      target: SessionDropTarget, childIndex: Int) -> SessionResolution? {
        let workspace: UUID
        let targetCount: Int
        let dropChildIndex: Int
        switch target {
        case let .workspaceRow(id, sessionCount):
            workspace = id
            targetCount = sessionCount
            dropChildIndex = childIndex
        case let .sessionRow(owner, sessionIndex, sessionCount):
            workspace = owner
            targetCount = sessionCount
            dropChildIndex = childIndex == onItemIndex ? sessionIndex + 1 : childIndex
        }

        let sameWorkspace = sourceWorkspace == workspace
        var destination = dropChildIndex
        if dropChildIndex == onItemIndex {
            destination = targetCount
        } else if sameWorkspace, sourceIndex < dropChildIndex {
            destination = dropChildIndex - 1
        }

        if sameWorkspace {
            // moveSession removes the source first (shrinking to targetCount - 1) then clamps, so the landed
            // slot is the clamped destination; equal to the source slot means no change.
            let landed = max(0, min(destination, targetCount - 1))
            if landed == sourceIndex { return nil }
        }
        return SessionResolution(workspace: workspace, dropChildIndex: dropChildIndex, destination: destination)
    }

    /// Resolves a batch session drop into one remove-all/insert-block move. `sources` must be in the
    /// dragged block's intended order. The returned destination is the target index AFTER all dragged
    /// sessions have been removed from their original workspaces.
    public static func resolveSessions(sources: [SessionSource],
                                       target: SessionDropTarget,
                                       childIndex: Int) -> SessionResolution? {
        guard !sources.isEmpty else { return nil }
        let workspace: UUID
        let targetCount: Int
        let dropChildIndex: Int
        switch target {
        case let .workspaceRow(id, sessionCount):
            workspace = id
            targetCount = sessionCount
            dropChildIndex = childIndex
        case let .sessionRow(owner, sessionIndex, sessionCount):
            workspace = owner
            targetCount = sessionCount
            dropChildIndex = childIndex == onItemIndex ? sessionIndex + 1 : childIndex
        }

        let rawDestination = dropChildIndex == onItemIndex ? targetCount : dropChildIndex
        let sourceIndicesInTarget = sources.filter { $0.workspace == workspace }.map(\.index).sorted()
        let removedBeforeDestination = sourceIndicesInTarget.count { $0 < rawDestination }
        let destination = rawDestination - removedBeforeDestination

        if let firstSourceIndex = sourceIndicesInTarget.first,
           sourceIndicesInTarget.count == sources.count,
           sourceIndicesInTarget == Array(firstSourceIndex..<firstSourceIndex + sourceIndicesInTarget.count),
           destination == firstSourceIndex {
            return nil
        }

        return SessionResolution(workspace: workspace, dropChildIndex: dropChildIndex, destination: destination)
    }

    /// Resolves an anchor-relative session placement (control `--after`/`--before <sid>`) into the same move
    /// `resolveSession` produces for a drag: `placeAfter` lands just after the anchor row (via `onItemIndex`,
    /// which maps to `anchorIndex + 1`), otherwise at the anchor's slot. Reuses the drop math verbatim, so
    /// the post-removal off-by-one, cross-workspace index space and anchor==source no-op all fall out
    /// unchanged. Returns nil for a no-op.
    public static func resolveRelative(source: (workspace: UUID, index: Int),
                                       anchor: (workspace: UUID, index: Int, count: Int),
                                       placeAfter: Bool) -> SessionResolution? {
        let target = SessionDropTarget.sessionRow(workspace: anchor.workspace, sessionIndex: anchor.index,
                                                  sessionCount: anchor.count)
        let childIndex = placeAfter ? onItemIndex : anchor.index
        return resolveSession(sourceWorkspace: source.workspace, sourceIndex: source.index,
                              target: target, childIndex: childIndex)
    }

    /// The destination of a dragged workspace, or nil when the drop is a no-op. `destination` is the
    /// POST-removal index `AppStore.moveWorkspace` expects; `dropChildIndex` is the PRE-removal slot to
    /// highlight (or `onItemIndex` to append). Same downward `childIndex - 1` adjustment as sessions.
    public struct WorkspaceResolution: Equatable, Sendable {
        public let dropChildIndex: Int
        public let destination: Int
    }

    /// Maps a drop slot read off the RENDERED workspace rows onto the FULL workspace array's index space,
    /// which is what `resolveWorkspace`/`AppStore.moveWorkspace` work in. `visibleIndices` holds the
    /// full-array indices of the rows the sidebar renders, in order — under the focus filter the marked
    /// set's, so possibly non-contiguous; `slot` is how many of those rows have their midpoint above the
    /// cursor (0 = above every rendered row).
    ///
    /// A drop lands IMMEDIATELY ADJACENT to the visible row it was aimed at, never at a raw array index the
    /// filter has no row for: above the first rendered row it takes that row's own index, otherwise the
    /// index just after the last rendered row above the cursor. Anything else would jump the dragged
    /// workspace across the hidden workspaces in between — invisible at drop time, revealed only once the
    /// filter is switched off. With every workspace rendered (`visibleIndices == Array(0..<count)`) it
    /// returns `slot` unchanged. Returns 0 for an empty `visibleIndices` (nothing to drop against).
    public static func workspaceInsertIndex(visibleIndices: [Int], slot: Int) -> Int {
        guard let firstVisible = visibleIndices.first else { return 0 }
        guard slot > 0 else { return firstVisible }
        return visibleIndices[min(slot, visibleIndices.count) - 1] + 1
    }

    /// The reparent a sidebar session drop resolves to within ONE workspace: the dragged block's new
    /// `parentID` (nil = the workspace's top level) and the destination index among that parent's DIRECT
    /// children AFTER the dragged roots are removed from the group. `AppStore.reparentSession(_:to:at:)`
    /// consumes it.
    public struct Reparent: Equatable, Sendable {
        public let parentID: UUID?
        public let destination: Int

        public init(parentID: UUID?, destination: Int) {
            self.parentID = parentID
            self.destination = destination
        }
    }

    /// Resolves a same-workspace session drop into a reparent. `parentID` is the drop's resolved parent — a
    /// session row the block nests under, or nil for a workspace-row / top-level-gap drop; `childIndex` is
    /// AppKit's proposed index among that parent's direct children (`onItemIndex` = dropped ON the row →
    /// last child). Returns nil for an ILLEGAL drop (the target is a dragged root or a descendant of one — a
    /// cycle) or a NO-OP (a single dragged root already parented here and landing back in its own slot).
    /// `order` is the workspace's flat session list (contiguity-valid); `sourceIDs` the dragged roots in
    /// drag order.
    public static func resolveReparent(order: [SessionTree.Node], sourceIDs: [UUID], parentID: UUID?,
                                       childIndex: Int) -> Reparent? {
        guard !sourceIDs.isEmpty else { return nil }
        let sources = Set(sourceIDs)
        if let parentID {
            guard order.contains(where: { $0.id == parentID }) else { return nil }
            // a cycle: the new parent is a dragged root, or nested inside one of them.
            for source in sourceIDs where SessionTree.isSelfOrDescendant(parentID, of: source, in: order) {
                return nil
            }
        }
        let directChildren = order.filter { $0.parentID == parentID }.map(\.id)
        let rawDestination = childIndex == onItemIndex ? directChildren.count
            : max(0, min(childIndex, directChildren.count))
        // dragged roots already in the target group shift the destination left by however many sit above it.
        let removedBefore = directChildren.enumerated().count { sources.contains($0.element) && $0.offset < rawDestination }
        let destination = rawDestination - removedBefore

        // no-op: a single dragged root already parented here, landing back in its own slot.
        if sourceIDs.count == 1, let only = sourceIDs.first, let slot = directChildren.firstIndex(of: only) {
            let landed = max(0, min(destination, directChildren.count - 1))
            if landed == slot { return nil }
        }
        return Reparent(parentID: parentID, destination: destination)
    }

    /// The flat index in `order` (the node list AFTER the moved block was removed) at which to insert that
    /// block so its root becomes `parent`'s child number `childDestination` (nil / out-of-range = last
    /// child). A nil `parent` positions among the top-level roots. Pure arithmetic over the contiguity
    /// invariant: a child's slot is just before the `childDestination`-th sibling's own subtree, or past the
    /// parent's whole subtree when appending.
    public static func flatChildInsertIndex(order: [SessionTree.Node], parent: UUID?, childDestination: Int?) -> Int {
        let children = order.filter { $0.parentID == parent }.map(\.id)
        let dest = childDestination.map { max(0, min($0, children.count)) } ?? children.count
        guard dest < children.count else { return SessionTree.appendChildIndex(parent: parent, in: order) }
        return SessionTree.subtreeRange(of: children[dest], in: order)?.lowerBound ?? order.count
    }

    /// Resolves a top-level workspace reorder (validity — a between-rows root drop — is the caller's
    /// to enforce). `count` is the pre-removal workspace count.
    public static func resolveWorkspace(sourceIndex: Int, count: Int, childIndex: Int) -> WorkspaceResolution? {
        let dropChildIndex = childIndex == onItemIndex ? count : childIndex
        var destination = dropChildIndex
        if sourceIndex < dropChildIndex { destination = dropChildIndex - 1 }
        if sourceIndex == destination { return nil }
        return WorkspaceResolution(dropChildIndex: dropChildIndex, destination: destination)
    }
}
