import Foundation
import Testing
@testable import agtermCore

struct SidebarDropTests {
    private static let wsA = UUID()
    private static let wsB = UUID()
    private static let onItem = SidebarDrop.onItemIndex

    // MARK: - Session, same workspace

    @Test func sessionSameWorkspaceUpDropOnRow() {
        // [a(0), b(1), c(2)]; drag c onto a's row → insert just after a (childIndex onItem → a's idx + 1 = 1).
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 2,
            target: .sessionRow(workspace: Self.wsA, sessionIndex: 0, sessionCount: 3), childIndex: Self.onItem)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 1, destination: 1))
    }

    @Test func sessionSameWorkspaceDownPastMiddleRowAppliesMinusOne() {
        // [a(0), b(1), c(2), d(3)]; drag a DOWN onto c's row (NOT the last) → insert after c.
        // childIndex onItem → c's idx + 1 = 3; same-workspace downward (0 < 3) subtracts 1 → destination 2.
        // This is the discriminating case: without the -1 the element would land at 3, not 2.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 0,
            target: .sessionRow(workspace: Self.wsA, sessionIndex: 2, sessionCount: 4), childIndex: Self.onItem)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 3, destination: 2))
    }

    @Test func sessionSameWorkspaceDownBetweenRowsAppliesMinusOne() {
        // [a(0), b(1), c(2), d(3)]; drag a into the slot before d (between-rows childIndex 3).
        // same-workspace downward (0 < 3) subtracts 1 → destination 2.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 0,
            target: .workspaceRow(id: Self.wsA, sessionCount: 4), childIndex: 3)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 3, destination: 2))
    }

    @Test func sessionSameWorkspaceUpBetweenRowsNoAdjustment() {
        // [a(0), b(1), c(2)]; drag c into the slot before b (between-rows childIndex 1). Upward (2 > 1),
        // so no -1; destination stays 1.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 2,
            target: .workspaceRow(id: Self.wsA, sessionCount: 3), childIndex: 1)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 1, destination: 1))
    }

    @Test func sessionSameWorkspaceNoOpWhenDroppedIntoOwnSlot() {
        // [a(0), b(1), c(2)]; drag b into the slot before c (between-rows childIndex 2). Downward (1 < 2)
        // subtracts 1 → destination 1 == sourceIndex → no-op.
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 1,
            target: .workspaceRow(id: Self.wsA, sessionCount: 3), childIndex: 2)
        #expect(move == nil)
    }

    @Test func sessionSameWorkspaceAppendAlreadyLastIsNoOp() {
        // [a(0), b(1), c(2)]; drop c ON its OWN workspace header (childIndex onItem → append at count 3).
        // moveSession removes c then clamps 3 to 2 → lands at 2 == sourceIndex → no-op (the bug fix: the
        // unclamped sourceIndex == destination check, 2 != 3, missed this).
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 2,
            target: .workspaceRow(id: Self.wsA, sessionCount: 3), childIndex: Self.onItem)
        #expect(move == nil)
    }

    @Test func sessionSameWorkspaceAppendFromMiddleMovesToEnd() {
        // [a(0), b(1), c(2)]; drop a ON its OWN workspace header (append at count 3). a is not last, so it
        // really moves to the end → not a no-op; destination 3 (moveSession clamps to land it last).
        let move = SidebarDrop.resolveSession(
            sourceWorkspace: Self.wsA, sourceIndex: 0,
            target: .workspaceRow(id: Self.wsA, sessionCount: 3), childIndex: Self.onItem)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: Self.onItem, destination: 3))
    }

    // MARK: - Session, cross workspace (no -1, no same-slot no-op)

    @Test func sessionCrossWorkspaceInsertAtMiddleSlot() {
        // target wsB = [x(0), y(1), z(2)]; drag a session from wsA into the slot before z (childIndex 2).
        // different workspace → no -1, destination 2 (precise placement, not append).
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

    // MARK: - Anchor-relative placement (control --after/--before)

    @Test func relativeSameWorkspaceAfterAnchor() {
        // [a(0), b(1), c(2)]; place c (source 2) AFTER a (anchor idx 0) → lands right after a at 1.
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 2), anchor: (Self.wsA, 0, 3), placeAfter: true)
        #expect(move == SidebarDrop.SessionResolution(workspace: Self.wsA, dropChildIndex: 1, destination: 1))
    }

    @Test func relativeSameWorkspaceAfterAnchorDownwardAppliesMinusOne() {
        // [a(0), b(1), c(2), d(3)]; place a (source 0) AFTER c (anchor idx 2). after → dropChildIndex 3;
        // same-workspace downward (0 < 3) subtracts 1 → destination 2 (the discriminating off-by-one).
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
        // [a(0), b(1), c(2)]; place b (source 1) BEFORE itself → lands in its own slot → no-op.
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 1), anchor: (Self.wsA, 1, 3), placeAfter: false)
        #expect(move == nil)
    }

    @Test func relativeAnchorIsSourceAfterIsNoOp() {
        // [a(0), b(1), c(2)]; place b (source 1) AFTER itself → after the -1 lands in its own slot → no-op.
        let move = SidebarDrop.resolveRelative(
            source: (Self.wsA, 1), anchor: (Self.wsA, 1, 3), placeAfter: true)
        #expect(move == nil)
    }

    // MARK: - Workspace reorder

    @Test func workspaceMoveUp() {
        // 3 workspaces; drag the one at index 2 into the slot before index 1 (between-rows childIndex 1).
        // upward (2 > 1) → no -1, destination 1.
        let move = SidebarDrop.resolveWorkspace(sourceIndex: 2, count: 3, childIndex: 1)
        #expect(move == SidebarDrop.WorkspaceResolution(dropChildIndex: 1, destination: 1))
    }

    @Test func workspaceMoveDownAppliesMinusOne() {
        // drag the workspace at index 0 into the slot before index 2 (between-rows childIndex 2).
        // downward (0 < 2) subtracts 1 → destination 1.
        let move = SidebarDrop.resolveWorkspace(sourceIndex: 0, count: 3, childIndex: 2)
        #expect(move == SidebarDrop.WorkspaceResolution(dropChildIndex: 2, destination: 1))
    }

    @Test func workspaceMoveToBottomAppend() {
        // drop at the end (childIndex onItem → count 3); source 0, downward → -1 → destination 2.
        let move = SidebarDrop.resolveWorkspace(sourceIndex: 0, count: 3, childIndex: Self.onItem)
        #expect(move == SidebarDrop.WorkspaceResolution(dropChildIndex: 3, destination: 2))
    }

    @Test func workspaceMoveNoOpIntoOwnSlot() {
        // drag the workspace at index 1 into the slot before index 2 (childIndex 2). downward (1 < 2)
        // subtracts 1 → destination 1 == sourceIndex → no-op.
        #expect(SidebarDrop.resolveWorkspace(sourceIndex: 1, count: 3, childIndex: 2) == nil)
    }

    @Test func workspaceMoveNoOpAppendAlreadyLast() {
        // workspace already last (index 2 of 3) dropped at the end (childIndex onItem → 3). 2 < 3
        // subtracts 1 → destination 2 == sourceIndex → no-op.
        #expect(SidebarDrop.resolveWorkspace(sourceIndex: 2, count: 3, childIndex: Self.onItem) == nil)
    }
}
