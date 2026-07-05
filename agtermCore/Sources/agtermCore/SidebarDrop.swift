import Foundation

/// SidebarDrop holds the pure index arithmetic for sidebar drag-and-drop reorder, so the trickiest
/// part of the drop handling (post-removal off-by-one, drop-on-row redirect, cross-workspace vs
/// same-parent index spaces, no-op detection) is host-free and table-testable. The AppKit/store glue
/// (reading the pasteboard, resolving the dragged/target ids) stays in `WorkspaceSidebar.Coordinator`,
/// which feeds resolved indices in and applies the returned destination via `AppStore`.
public enum SidebarDrop {
    /// Mirrors AppKit's `NSOutlineViewDropOnItemIndex`: a drop landing ON a row rather than between rows.
    public static let onItemIndex = -1

    /// The destination of a dragged session, or nil when the drop is a no-op (would leave order
    /// unchanged). `destination` is the POST-removal index `AppStore.moveSession` expects; `dropChildIndex`
    /// is the PRE-removal slot to highlight in the outline (or `onItemIndex` to append).
    public struct SessionResolution: Equatable, Sendable {
        public let workspace: UUID
        public let dropChildIndex: Int
        public let destination: Int
    }

    /// Describes the row a session was dropped onto. A workspace row uses the child index directly; a
    /// session row redirects to its owner workspace, landing just after it when dropped ON the row.
    public enum SessionDropTarget: Equatable, Sendable {
        case workspaceRow(id: UUID, sessionCount: Int)
        case sessionRow(workspace: UUID, sessionIndex: Int, sessionCount: Int)
    }

    /// Resolves a session drop into the move it would perform (target workspace + post-removal index),
    /// or nil for a no-op. `childIndex` is AppKit's proposed child index (`onItemIndex` for a drop ON
    /// the target). For a same-workspace DOWNWARD move the slot shifts up by one after the removal, so
    /// 1 is subtracted; cross-workspace and upward moves pass through. A same-workspace move that lands
    /// the session back in its current slot (including appending an already-last session) is a no-op.
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
            // moveSession removes the source first (shrinking the array to targetCount - 1), then clamps,
            // so the landed slot is the clamped destination; equal to the source slot means no change.
            let landed = max(0, min(destination, targetCount - 1))
            if landed == sourceIndex { return nil }
        }
        return SessionResolution(workspace: workspace, dropChildIndex: dropChildIndex, destination: destination)
    }

    /// Resolves an anchor-relative session placement (control `--after`/`--before <sid>`) into the same
    /// move `resolveSession` produces for a drag. `placeAfter` lands just after the anchor row (via
    /// `onItemIndex`, which maps to `anchorIndex + 1`); otherwise it lands at the anchor's slot. Reuses
    /// the drop math verbatim, so the post-removal off-by-one, cross-workspace index space, and
    /// anchor==source no-op all fall out unchanged. Returns nil for a no-op.
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
