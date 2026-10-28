import Foundation
import Testing
@testable import agtermCore

struct SidebarDropTests {
    private static let wsA = UUID()
    private static let wsB = UUID()
    private static let onItem = SidebarDrop.onItemIndex

    // MARK: - Finder directory import

    @Test func directoryDropTargetsExplicitRowWorkspace() {
        #expect(SidebarDrop.resolveDirectoryWorkspace(
            sidebarMode: .tree, rowWorkspaceID: Self.wsB,
            fallbackWorkspaceID: Self.wsA, currentWorkspaceID: Self.wsA) == Self.wsB)
    }

    @Test func emptyDirectoryDropPrefersTheFallbackWorkspace() {
        #expect(SidebarDrop.resolveDirectoryWorkspace(
            sidebarMode: .tree, rowWorkspaceID: nil,
            fallbackWorkspaceID: Self.wsB, currentWorkspaceID: Self.wsA) == Self.wsB)
    }

    @Test func emptyDirectoryDropFallsBackToCurrentWorkspace() {
        #expect(SidebarDrop.resolveDirectoryWorkspace(
            sidebarMode: .tree, rowWorkspaceID: nil,
            fallbackWorkspaceID: nil, currentWorkspaceID: Self.wsA) == Self.wsA)
    }

    @Test func directoryDropIsRejectedInFlaggedMode() {
        #expect(SidebarDrop.resolveDirectoryWorkspace(
            sidebarMode: .flagged, rowWorkspaceID: Self.wsB,
            fallbackWorkspaceID: nil, currentWorkspaceID: Self.wsA) == nil)
    }

    // MARK: - Session, same workspace

    @Test func sessionSameWorkspaceUpDropOnRow() {
        // [a(0), b(1), c(2)]; drag c onto a's row → insert just after a (childIndex onItem → a's idx + 1 = 1).
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 2,
            target: .sessionRow(workspace: Self.wsA, sessionIndex: 0, sessionCount: 3), childIndex: Self.onItem)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 1, destination: 1))
    }

    @Test func sessionSameWorkspaceDownPastMiddleRowAppliesMinusOne() {
        // [a(0), b(1), c(2), d(3)]; drag a DOWN onto c's row → insert after c at 3, then same-workspace
        // downward subtracts 1 → 2. Discriminating case: without the -1 the element lands at 3.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 0,
            target: .sessionRow(workspace: Self.wsA, sessionIndex: 2, sessionCount: 4), childIndex: Self.onItem)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 3, destination: 2))
    }

    @Test func sessionSameWorkspaceDownBetweenRowsAppliesMinusOne() {
        // [a(0), b(1), c(2), d(3)]; drag a into the slot before d (childIndex 3); downward subtracts 1 → 2.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 0,
            target: .workspaceRow(id: Self.wsA, sessionCount: 4), childIndex: 3)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 3, destination: 2))
    }

    @Test func sessionSameWorkspaceUpBetweenRowsNoAdjustment() {
        // [a(0), b(1), c(2)]; drag c into the slot before b (childIndex 1). Upward (2 > 1), so no -1.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 2,
            target: .workspaceRow(id: Self.wsA, sessionCount: 3), childIndex: 1)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 1, destination: 1))
    }

    @Test func sessionSameWorkspaceNoOpWhenDroppedIntoOwnSlot() {
        // [a(0), b(1), c(2)]; drag b into the slot before c (childIndex 2); downward -1 → 1 == sourceIndex.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 1,
            target: .workspaceRow(id: Self.wsA, sessionCount: 3), childIndex: 2)
        #expect(move == nil)
    }

    @Test func sessionSameWorkspaceAppendAlreadyLastIsNoOp() {
        // [a(0), b(1), c(2)]; drop c ON its OWN workspace header (append at count 3). moveSession removes c
        // then clamps 3 to 2 == sourceIndex; an unclamped sourceIndex == destination check (2 != 3) misses it.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 2,
            target: .workspaceRow(id: Self.wsA, sessionCount: 3), childIndex: Self.onItem)
        #expect(move == nil)
    }

    @Test func sessionSameWorkspaceAppendFromMiddleMovesToEnd() {
        // [a(0), b(1), c(2)]; drop a ON its OWN header (append at 3). a is not last, so this really moves.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 0,
            target: .workspaceRow(id: Self.wsA, sessionCount: 3), childIndex: Self.onItem)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: Self.onItem, destination: 3))
    }

    // MARK: - Session, cross workspace (no -1, no same-slot no-op)

    @Test func sessionCrossWorkspaceInsertAtMiddleSlot() {
        // wsB = [x(0), y(1), z(2)]; a wsA session into the slot before z; cross-workspace, so no -1.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 0,
            target: .workspaceRow(id: Self.wsB, sessionCount: 3), childIndex: 2)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: 2, destination: 2))
    }

    @Test func sessionCrossWorkspaceDropOnRowInsertsAfter() {
        // drop a wsA session ON wsB's row y (idx 1) → insert after y at index 2; cross-workspace, no -1.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 0,
            target: .sessionRow(workspace: Self.wsB, sessionIndex: 1, sessionCount: 3), childIndex: Self.onItem)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: 2, destination: 2))
    }

    @Test func sessionCrossWorkspaceAppendOntoHeader() {
        // drop a wsA session ON wsB's header (append) → destination = wsB count, no same-slot no-op.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 0,
            target: .workspaceRow(id: Self.wsB, sessionCount: 2), childIndex: Self.onItem)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: Self.onItem, destination: 2))
    }

    // MARK: - Batch session drag

    @Test func batchSessionCrossWorkspaceInsertAtMiddleSlot() {
        let move = SidebarDrop.resolveSessions(
            sources: [
                SidebarDrop.SessionSource(workspace: Self.wsA, index: 0),
                SidebarDrop.SessionSource(workspace: Self.wsA, index: 1)
            ],
            target: .workspaceRow(id: Self.wsB, sessionCount: 3), childIndex: 2)

        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: 2, destination: 2))
    }

    @Test func batchSessionSameWorkspaceDownAdjustsForEveryRemovedSourceBeforeDrop() {
        // [a, b, c, d, e]; drag [a, b] into the slot before e (childIndex 4). Removing a+b first leaves
        // [c, d, e], so the block lands at post-removal index 2.
        let move = SidebarDrop.resolveSessions(
            sources: [
                SidebarDrop.SessionSource(workspace: Self.wsA, index: 0),
                SidebarDrop.SessionSource(workspace: Self.wsA, index: 1)
            ],
            target: .workspaceRow(id: Self.wsA, sessionCount: 5), childIndex: 4)

        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 4, destination: 2))
    }

    @Test func batchSessionSameWorkspaceContiguousDropInsideSelectionIsNoOp() {
        // [a, b, c, d]; dragging contiguous [b, c] into any slot inside its own block leaves order unchanged.
        let move = SidebarDrop.resolveSessions(
            sources: [
                SidebarDrop.SessionSource(workspace: Self.wsA, index: 1),
                SidebarDrop.SessionSource(workspace: Self.wsA, index: 2)
            ],
            target: .workspaceRow(id: Self.wsA, sessionCount: 4), childIndex: 2)

        #expect(move == nil)
    }

    @Test func batchSessionSameWorkspaceNonContiguousDropAtFirstSourceCanStillMove() {
        // [a, b, c, d, e]; dragging non-contiguous [b, d] before b compacts the selection to [b, d],
        // so it is a real reorder even though the insertion slot is the first selected index.
        let move = SidebarDrop.resolveSessions(
            sources: [
                SidebarDrop.SessionSource(workspace: Self.wsA, index: 1),
                SidebarDrop.SessionSource(workspace: Self.wsA, index: 3)
            ],
            target: .workspaceRow(id: Self.wsA, sessionCount: 5), childIndex: 1)

        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 1, destination: 1))
    }

    @Test func batchSessionMixedTargetAdjustsForMovedRowsAlreadyInTarget() {
        // target wsB = [x, y, z]; dragging [a-from-wsA, x-from-wsB] before z removes x first, so the
        // post-removal insertion index shifts from 2 to 1.
        let move = SidebarDrop.resolveSessions(
            sources: [
                SidebarDrop.SessionSource(workspace: Self.wsA, index: 0),
                SidebarDrop.SessionSource(workspace: Self.wsB, index: 0)
            ],
            target: .workspaceRow(id: Self.wsB, sessionCount: 3), childIndex: 2)

        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: 2, destination: 1))
    }

    // MARK: - Anchor-relative placement (control --after/--before)

    @Test func relativeSameWorkspaceAfterAnchor() {
        // [a(0), b(1), c(2)]; place c (source 2) AFTER a (anchor idx 0) → lands right after a at 1.
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 2), anchor: (Self.wsA, 0, 3), placeAfter: true)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 1, destination: 1))
    }

    @Test func relativeSameWorkspaceAfterAnchorDownwardAppliesMinusOne() {
        // [a(0), b(1), c(2), d(3)]; place a (source 0) AFTER c (anchor idx 2) → dropChildIndex 3, then
        // same-workspace downward subtracts 1 → 2 (the discriminating off-by-one).
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 0), anchor: (Self.wsA, 2, 4), placeAfter: true)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 3, destination: 2))
    }

    @Test func relativeSameWorkspaceBeforeAnchor() {
        // [a(0), b(1), c(2)]; place c (source 2) BEFORE b (anchor idx 1) → childIndex = anchorIndex = 1.
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 2), anchor: (Self.wsA, 1, 3), placeAfter: false)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 1, destination: 1))
    }

    @Test func relativeCrossWorkspaceAfterAnchorNoAdjustment() {
        // place a wsA session AFTER wsB's y (anchor idx 1) → dropChildIndex 2; cross-workspace, no -1.
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 0), anchor: (Self.wsB, 1, 3), placeAfter: true)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: 2, destination: 2))
    }

    @Test func relativeCrossWorkspaceBeforeAnchorNoAdjustment() {
        // place a wsA session BEFORE wsB's y (anchor idx 1) → childIndex 1; cross-workspace, no -1.
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 0), anchor: (Self.wsB, 1, 3), placeAfter: false)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: 1, destination: 1))
    }

    @Test func relativeAnchorIsSourceBeforeIsNoOp() {
        // [a(0), b(1), c(2)]; place b (source 1) BEFORE itself → lands in its own slot.
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 1), anchor: (Self.wsA, 1, 3), placeAfter: false)
        #expect(move == nil)
    }

    @Test func relativeAnchorIsSourceAfterIsNoOp() {
        // [a(0), b(1), c(2)]; place b (source 1) AFTER itself → after the -1 it lands in its own slot.
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 1), anchor: (Self.wsA, 1, 3), placeAfter: true)
        #expect(move == nil)
    }

    // MARK: - Workspace reorder

    @Test func workspaceMoveUp() {
        // 3 workspaces; drag index 2 into the slot before index 1 (childIndex 1). Upward, so no -1.
        let move = SidebarDrop.resolveWorkspace(sourceIndex: 2, count: 3, childIndex: 1)
        #expect(move == SidebarDrop.WorkspaceResolution(dropChildIndex: 1, destination: 1))
    }

    @Test func workspaceMoveDownAppliesMinusOne() {
        // drag index 0 into the slot before index 2 (childIndex 2); downward subtracts 1 → 1.
        let move = SidebarDrop.resolveWorkspace(sourceIndex: 0, count: 3, childIndex: 2)
        #expect(move == SidebarDrop.WorkspaceResolution(dropChildIndex: 2, destination: 1))
    }

    @Test func workspaceMoveToBottomAppend() {
        // drop at the end (childIndex onItem → count 3); source 0, downward → -1 → destination 2.
        let move = SidebarDrop.resolveWorkspace(sourceIndex: 0, count: 3, childIndex: Self.onItem)
        #expect(move == SidebarDrop.WorkspaceResolution(dropChildIndex: 3, destination: 2))
    }

    @Test func workspaceMoveNoOpIntoOwnSlot() {
        // drag index 1 into the slot before index 2 (childIndex 2); downward -1 → 1 == sourceIndex.
        #expect(SidebarDrop.resolveWorkspace(sourceIndex: 1, count: 3, childIndex: 2) == nil)
    }

    @Test func workspaceMoveNoOpAppendAlreadyLast() {
        // index 2 of 3 (already last) dropped at the end (onItem → 3); -1 → 2 == sourceIndex.
        #expect(SidebarDrop.resolveWorkspace(sourceIndex: 2, count: 3, childIndex: Self.onItem) == nil)
    }

    // MARK: - Workspace reorder against a FILTERED tree

    @Test func workspaceInsertIndexPassesTheSlotThroughOnAnUnfilteredTree() {
        // every workspace rendered: the visible slot IS the full-array index, append slot included.
        let all = Array(0..<4)
        #expect((0...4).allSatisfy { SidebarDrop.workspaceInsertIndex(visibleIndices: all, slot: $0) == $0 })
    }

    @Test func workspaceInsertIndexAboveTheFirstVisibleRowTakesThatRowsIndex() {
        // marked set {B(1), D(3)} of A B C D; dropping above B must land at 1 (just before B), NOT at 0 —
        // slot 0 read as a full-array index would jump the dragged workspace ahead of the hidden A.
        #expect(SidebarDrop.workspaceInsertIndex(visibleIndices: [1, 3], slot: 0) == 1)
    }

    @Test func workspaceInsertIndexLandsJustAfterTheLastRowAboveTheCursor() {
        // same marked set: below B's midpoint but above D's (slot 1) lands at 2 — immediately after B,
        // ahead of the hidden C — and below D's midpoint (slot 2) lands at 4, immediately after D.
        #expect(SidebarDrop.workspaceInsertIndex(visibleIndices: [1, 3], slot: 1) == 2)
        #expect(SidebarDrop.workspaceInsertIndex(visibleIndices: [1, 3], slot: 2) == 4)
    }

    @Test func workspaceInsertIndexClampsASlotPastTheLastVisibleRow() {
        #expect(SidebarDrop.workspaceInsertIndex(visibleIndices: [0, 2], slot: 9) == 3)
    }

    @Test func workspaceInsertIndexWithNoVisibleRows() {
        #expect(SidebarDrop.workspaceInsertIndex(visibleIndices: [], slot: 0) == 0)
        #expect(SidebarDrop.workspaceInsertIndex(visibleIndices: [], slot: 3) == 0)
    }

    @Test func filteredWorkspaceDropBeforeTheFirstVisibleRowKeepsTheHiddenWorkspaceAhead() {
        // A B C D with {B, D} marked: drag D above B. The mapped index 1 leaves hidden A first; the raw
        // slot 0 would have jumped D ahead of A too — a reorder the user never saw and could not aim at.
        let insert = SidebarDrop.workspaceInsertIndex(visibleIndices: [1, 3], slot: 0)
        let move = SidebarDrop.resolveWorkspace(sourceIndex: 3, count: 4, childIndex: insert)
        #expect(move == SidebarDrop.WorkspaceResolution(dropChildIndex: 1, destination: 1))
    }

    @Test func filteredWorkspaceDropOntoItsOwnSlotIsStillANoOp() {
        // {B(1), D(3)} marked, drag B and release just below its own midpoint (slot 1 → insert 2):
        // downward subtracts 1 → destination 1 == source, so validate and accept both reject it.
        let insert = SidebarDrop.workspaceInsertIndex(visibleIndices: [1, 3], slot: 1)
        #expect(SidebarDrop.resolveWorkspace(sourceIndex: 1, count: 4, childIndex: insert) == nil)
    }

    private static let ids = (0..<8).map { _ in UUID() }
    private static let flat = Array(ids[0..<4])

    @Test(arguments: [
        ((dragged: [3], onRow: nil as Int?, slot: 0), (ids: [3], placement: FlaggedOrderPlacement.before, anchor: 0)),
        ((dragged: [0], onRow: nil, slot: 4), (ids: [0], placement: .after, anchor: 3)),
        ((dragged: [0], onRow: nil, slot: 2), (ids: [0], placement: .before, anchor: 2)),
        ((dragged: [1], onRow: 3, slot: -1), (ids: [1], placement: .after, anchor: 3)),
        ((dragged: [2, 0], onRow: nil, slot: 2), (ids: [0, 2], placement: .before, anchor: 3)),
        ((dragged: [3, 2], onRow: nil, slot: 0), (ids: [2, 3], placement: .before, anchor: 0)),
    ])
    func flatDropResolvesToAMoveOfTheBlockInListOrder(
        drop: (dragged: [Int], onRow: Int?, slot: Int),
        want: (ids: [Int], placement: FlaggedOrderPlacement, anchor: Int)
    ) throws {
        let move = try #require(SidebarDrop.resolveFlaggedReorder(
            order: Self.flat, dragged: drop.dragged.map { Self.flat[$0] }, onRow: drop.onRow.map { Self.flat[$0] },
            childIndex: drop.slot))
        #expect(move == SidebarDrop.FlaggedReorder(ids: want.ids.map { Self.flat[$0] }, placement: want.placement,
                                                   anchor: Self.flat[want.anchor]))
    }

    @Test(arguments: [
        (dragged: [1], onRow: nil as Int?, slot: 1),
        (dragged: [1], onRow: nil, slot: 2),
        (dragged: [1], onRow: 1, slot: -1),
        (dragged: [1], onRow: 0, slot: -1),
        (dragged: [3], onRow: nil, slot: 4),
        (dragged: [0, 1], onRow: nil, slot: 0),
        (dragged: [0, 1, 2, 3], onRow: nil, slot: 2),
    ])
    func flatDropThatKeepsTheOrderIsANoOp(dragged: [Int], onRow: Int?, slot: Int) {
        #expect(SidebarDrop.resolveFlaggedReorder(
            order: Self.flat, dragged: dragged.map { Self.flat[$0] }, onRow: onRow.map { Self.flat[$0] },
            childIndex: slot) == nil)
    }

    @Test(arguments: [
        (moving: [3, 1], placement: FlaggedOrderPlacement.before, anchor: 0, want: [1, 3, 0, 2] as [Int]?),
        (moving: [0], placement: .after, anchor: 3, want: [1, 2, 3, 0]),
        (moving: [1], placement: .before, anchor: 2, want: nil),
        (moving: [1], placement: .after, anchor: 0, want: nil),
        (moving: [1], placement: .before, anchor: 1, want: nil),
    ])
    func reorderedFlaggedMovesTheBlockInListOrder(moving: [Int], placement: FlaggedOrderPlacement, anchor: Int,
                                                  want: [Int]?) {
        #expect(SidebarDrop.reorderedFlagged(Self.flat, moving: Set(moving.map { Self.flat[$0] }),
                                             placement: placement, anchor: Self.flat[anchor])
            == want.map { $0.map { Self.flat[$0] } })
    }

    @Test func reorderedFlaggedWithAnAnchorOutsideTheListIsNil() {
        #expect(SidebarDrop.reorderedFlagged(Self.flat, moving: [Self.flat[0]], placement: .before, anchor: UUID()) == nil)
    }

    @Test func flatDropOfRowsOutsideTheListIsANoOp() {
        #expect(SidebarDrop.resolveFlaggedReorder(order: Self.flat, dragged: [UUID()], onRow: nil, childIndex: 0) == nil)
        #expect(SidebarDrop.resolveFlaggedReorder(order: [], dragged: [Self.flat[0]], onRow: nil, childIndex: 0) == nil)
    }

    @Test(arguments: [
        (visible: [1, 3], slot: 0, want: 1),
        (visible: [1, 3], slot: 1, want: 3),
        (visible: [1, 3], slot: 2, want: 4),
        (visible: [0, 1], slot: 2, want: 2),
        (visible: [1, 3], slot: SidebarDrop.onItemIndex, want: SidebarDrop.onItemIndex),
        (visible: [], slot: 0, want: 0),
    ])
    func flaggedTreeGapMapsNextToTheVisibleRowItWasAimedAt(visible: [Int], slot: Int, want: Int) {
        #expect(SidebarDrop.flaggedTreeChildIndex(visibleIndices: visible, slot: slot) == want)
    }

    private static let (a, h, b, c, k) = (ids[0], ids[1], ids[2], ids[3], ids[4])
    private static let tree = SidebarDrop.FlaggedTree(
        workspaces: [(id: wsA, sessions: [a, h, b]), (id: wsB, sessions: [c, k])], flagged: [a, b, c])

    private enum TreeTarget {
        case gap(workspace: UUID, visible: [Int], count: Int, slot: Int)
        case onWorkspace(UUID, count: Int)
        case onSession(workspace: UUID, index: Int, count: Int)
    }

    private func treeDrop(_ dragged: UUID, from source: (UUID, Int), _ target: TreeTarget) -> SidebarDrop.SessionResolution? {
        let sources = [SidebarDrop.SessionSource(workspace: source.0, index: source.1)]
        let resolution: SidebarDrop.SessionResolution?
        switch target {
        case let .gap(workspace, visible, count, slot):
            resolution = SidebarDrop.resolveSessions(
                sources: sources, target: .workspaceRow(id: workspace, sessionCount: count),
                childIndex: SidebarDrop.flaggedTreeChildIndex(visibleIndices: visible, slot: slot))
        case let .onWorkspace(workspace, count):
            resolution = SidebarDrop.resolveSessions(
                sources: sources, target: .workspaceRow(id: workspace, sessionCount: count),
                childIndex: SidebarDrop.flaggedTreeChildIndex(visibleIndices: [], slot: Self.onItem))
        case let .onSession(workspace, index, count):
            resolution = SidebarDrop.resolveSessions(
                sources: sources, target: .sessionRow(workspace: workspace, sessionIndex: index, sessionCount: count),
                childIndex: Self.onItem)
        }
        guard let resolution, Self.tree.changesView(moving: [dragged], to: resolution) else { return nil }
        return resolution
    }

    @Test func flaggedTreeDropBackAboveTheNextFlaggedRowAcrossAHiddenSiblingIsANoOp() {
        #expect(treeDrop(Self.a, from: (Self.wsA, 0), .gap(workspace: Self.wsA, visible: [0, 2], count: 3, slot: 1)) == nil)
    }

    @Test func flaggedTreeReorderInsideAWorkspaceKeepsTheHiddenSiblingInPlace() {
        let up = treeDrop(Self.b, from: (Self.wsA, 2), .gap(workspace: Self.wsA, visible: [0, 2], count: 3, slot: 0))
        #expect(up == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 0, destination: 0))
        let down = treeDrop(Self.a, from: (Self.wsA, 0), .gap(workspace: Self.wsA, visible: [0, 2], count: 3, slot: 2))
        #expect(down == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 3, destination: 2))
    }

    @Test func flaggedTreeMoveToAnotherWorkspaceCountsEvenWhenTheFlatOrderStaysTheSame() {
        let move = treeDrop(Self.b, from: (Self.wsA, 2), .gap(workspace: Self.wsB, visible: [0], count: 2, slot: 0))
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: 0, destination: 0))
    }

    @Test func flaggedTreeEndOfGroupGapLandsRightAfterTheLastFlaggedRow() {
        let move = treeDrop(Self.a, from: (Self.wsA, 0), .gap(workspace: Self.wsB, visible: [0], count: 2, slot: 1))
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: 1, destination: 1))
    }

    @Test func flaggedTreeDropOnAWorkspaceRowAppendsAfterItsLastSession() {
        let move = treeDrop(Self.a, from: (Self.wsA, 0), .onWorkspace(Self.wsB, count: 2))
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: Self.onItem, destination: 2))
    }

    @Test func flaggedTreeDropOnASessionRowLandsRightAfterIt() {
        let move = treeDrop(Self.a, from: (Self.wsA, 0), .onSession(workspace: Self.wsB, index: 0, count: 2))
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsB, dropChildIndex: 1, destination: 1))
    }

    @Test func flaggedTreeDropOnItsOwnRowIsANoOp() {
        #expect(treeDrop(Self.b, from: (Self.wsA, 2), .onSession(workspace: Self.wsA, index: 2, count: 3)) == nil)
    }
}
