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

    /// Resolves a top-level workspace reorder (validity — a between-rows root drop — is the caller's
    /// to enforce). `count` is the pre-removal workspace count.
    public static func resolveWorkspace(sourceIndex: Int, count: Int, childIndex: Int) -> WorkspaceResolution? {
        let dropChildIndex = childIndex == onItemIndex ? count : childIndex
        var destination = dropChildIndex
        if sourceIndex < dropChildIndex { destination = dropChildIndex - 1 }
        if sourceIndex == destination { return nil }
        return WorkspaceResolution(dropChildIndex: dropChildIndex, destination: destination)
    }

    // MARK: - Flagged view

    /// FlaggedReorder is a flat or plain flagged-list drop resolved into the arguments of
    /// `AppStore.moveFlagged`.
    public struct FlaggedReorder: Equatable, Sendable {
        public let ids: [UUID]
        public let placement: FlaggedOrderPlacement
        public let anchor: UUID
    }

    /// resolveFlaggedReorder resolves a drop on the flat or plain flagged list, whose rows are `order`. A drop
    /// ON a row (`onRow`) lands after it. A gap drop at `childIndex` lands before the first undragged row at or
    /// below the gap, else after the last undragged row above it. Nil when the order would not change.
    public static func resolveFlaggedReorder(order: [UUID], dragged: [UUID], onRow: UUID?,
                                             childIndex: Int) -> FlaggedReorder? {
        let moving = Set(dragged)
        let block = order.filter { moving.contains($0) }
        guard !block.isEmpty else { return nil }
        let placement: FlaggedOrderPlacement
        let anchor: UUID
        if let onRow {
            guard !moving.contains(onRow), order.contains(onRow) else { return nil }
            (placement, anchor) = (.after, onRow)
        } else {
            let slot = max(0, min(childIndex, order.count))
            if let below = order[slot...].first(where: { !moving.contains($0) }) {
                (placement, anchor) = (.before, below)
            } else if let above = order[..<slot].last(where: { !moving.contains($0) }) {
                (placement, anchor) = (.after, above)
            } else {
                return nil
            }
        }
        guard reorderedFlagged(order, moving: moving, placement: placement, anchor: anchor) != nil else { return nil }
        return FlaggedReorder(ids: block, placement: placement, anchor: anchor)
    }

    // shared with AppStore.moveFlagged so a drop the sidebar accepts is the move the store applies
    static func reorderedFlagged(_ order: [UUID], moving: Set<UUID>, placement: FlaggedOrderPlacement,
                                 anchor: UUID) -> [UUID]? {
        var reordered = order.filter { !moving.contains($0) }
        guard let anchorIndex = reordered.firstIndex(of: anchor) else { return nil }
        reordered.insert(contentsOf: order.filter { moving.contains($0) },
                         at: placement == .before ? anchorIndex : anchorIndex + 1)
        return reordered == order ? nil : reordered
    }

    /// flaggedTreeChildIndex maps a gap among a flagged-tree workspace's visible rows to the full workspace's
    /// pre-removal child index `resolveSessions` takes. `visibleIndices` are the flagged rows' full indices,
    /// ascending. A gap above a visible row lands right before it and the gap after the last one right after
    /// it, so a hidden unflagged sibling never crosses the drop. `onItemIndex`, a drop ON the workspace row,
    /// passes through and appends after the workspace's last session, flagged or not.
    public static func flaggedTreeChildIndex(visibleIndices: [Int], slot: Int) -> Int {
        guard slot != onItemIndex else { return onItemIndex }
        guard let last = visibleIndices.last else { return 0 }
        guard slot < visibleIndices.count else { return last + 1 }
        return visibleIndices[max(0, slot)]
    }

    /// FlaggedTree is the workspace tree as the flagged tree layout sees it: every session, and which are
    /// flagged.
    public struct FlaggedTree: Sendable {
        public let workspaces: [(id: UUID, sessions: [UUID])]
        public let flagged: Set<UUID>

        public init(workspaces: [(id: UUID, sessions: [UUID])], flagged: Set<UUID>) {
            self.workspaces = workspaces
            self.flagged = flagged
        }

        /// changesView says whether moving `dragged` as `resolution` describes changes any workspace's flagged
        /// rows or their order. A move that only shifts hidden unflagged siblings, which the full-tree no-op
        /// check in `resolveSessions` cannot see, changes nothing on screen.
        public func changesView(moving dragged: [UUID], to resolution: SessionResolution) -> Bool {
            let moving = Set(dragged)
            var after = workspaces.map { (id: $0.id, sessions: $0.sessions.filter { !moving.contains($0) }) }
            guard let target = after.firstIndex(where: { $0.id == resolution.workspace }) else { return false }
            let destination = max(0, min(resolution.destination, after[target].sessions.count))
            after[target].sessions.insert(contentsOf: dragged, at: destination)
            return flaggedRows(after) != flaggedRows(workspaces)
        }

        private func flaggedRows(_ tree: [(id: UUID, sessions: [UUID])]) -> [[UUID]] {
            tree.map { $0.sessions.filter(flagged.contains) }
        }
    }
}
