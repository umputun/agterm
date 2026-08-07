import Foundation
import Testing
@testable import agtermCore

struct SessionTreeTests {
    // Fixture: [A, A/b, A/b/c, A/d, E] — a 3-level tree plus an unrelated root, in canonical preorder.
    private static let idA = UUID()
    private static let idB = UUID()
    private static let idC = UUID()
    private static let idD = UUID()
    private static let idE = UUID()

    private static var fixture: [SessionTree.Node] {
        [
            SessionTree.Node(id: idA, parentID: nil),
            SessionTree.Node(id: idB, parentID: idA),
            SessionTree.Node(id: idC, parentID: idB),
            SessionTree.Node(id: idD, parentID: idA),
            SessionTree.Node(id: idE, parentID: nil),
        ]
    }

    @Test func subtreeRangeCoversRootAndWholeSubtree() {
        #expect(SessionTree.subtreeRange(of: Self.idA, in: Self.fixture) == 0..<4)
    }

    @Test func subtreeRangeCoversMidLevelNodeAndItsChild() {
        #expect(SessionTree.subtreeRange(of: Self.idB, in: Self.fixture) == 1..<3)
    }

    @Test func subtreeRangeOfLeafIsSingleElement() {
        #expect(SessionTree.subtreeRange(of: Self.idC, in: Self.fixture) == 2..<3)
    }

    @Test func subtreeRangeUnknownIDIsNil() {
        #expect(SessionTree.subtreeRange(of: UUID(), in: Self.fixture) == nil)
    }

    @Test func subtreeRangeEmptyOrderIsNil() {
        #expect(SessionTree.subtreeRange(of: Self.idA, in: []) == nil)
    }

    @Test func descendantIDsExcludesSelfInTreeOrder() {
        #expect(SessionTree.descendantIDs(of: Self.idA, in: Self.fixture) == [Self.idB, Self.idC, Self.idD])
    }

    @Test func descendantIDsOfLeafIsEmpty() {
        #expect(SessionTree.descendantIDs(of: Self.idC, in: Self.fixture) == [])
    }

    @Test func descendantIDsUnknownIDIsEmpty() {
        #expect(SessionTree.descendantIDs(of: UUID(), in: Self.fixture) == [])
    }

    @Test func isSelfOrDescendantTrueForDescendant() {
        #expect(SessionTree.isSelfOrDescendant(Self.idC, of: Self.idA, in: Self.fixture))
    }

    @Test func isSelfOrDescendantTrueForSelf() {
        #expect(SessionTree.isSelfOrDescendant(Self.idA, of: Self.idA, in: Self.fixture))
    }

    @Test func isSelfOrDescendantFalseForAncestor() {
        #expect(!SessionTree.isSelfOrDescendant(Self.idA, of: Self.idC, in: Self.fixture))
    }

    @Test func isSelfOrDescendantFalseForUnrelatedNode() {
        #expect(!SessionTree.isSelfOrDescendant(Self.idE, of: Self.idA, in: Self.fixture))
    }

    @Test func appendChildIndexUnderParentIsPastItsSubtree() {
        #expect(SessionTree.appendChildIndex(parent: Self.idA, in: Self.fixture) == 4)
    }

    @Test func appendChildIndexTopLevelIsOrderCount() {
        #expect(SessionTree.appendChildIndex(parent: nil, in: Self.fixture) == 5)
    }

    @Test func appendChildIndexUnknownParentIsOrderCount() {
        #expect(SessionTree.appendChildIndex(parent: UUID(), in: Self.fixture) == 5)
    }

    @Test func ancestorIDsNearestFirstUpToRoot() {
        #expect(SessionTree.ancestorIDs(of: Self.idC, in: Self.fixture) == [Self.idB, Self.idA])
    }

    @Test func ancestorIDsOfRootIsEmpty() {
        #expect(SessionTree.ancestorIDs(of: Self.idA, in: Self.fixture) == [])
    }

    @Test func ancestorIDsUnknownIDIsEmpty() {
        #expect(SessionTree.ancestorIDs(of: UUID(), in: Self.fixture) == [])
    }

    @Test func preorderRepairsScrambledButValidParentIDs() {
        // Same nodes as the fixture, listed out of contiguity order; parentIDs alone must drive the repair.
        let scrambled = [
            SessionTree.Node(id: Self.idE, parentID: nil),
            SessionTree.Node(id: Self.idD, parentID: Self.idA),
            SessionTree.Node(id: Self.idC, parentID: Self.idB),
            SessionTree.Node(id: Self.idA, parentID: nil),
            SessionTree.Node(id: Self.idB, parentID: Self.idA),
        ]
        #expect(SessionTree.preorder(scrambled) == [Self.idE, Self.idA, Self.idD, Self.idB, Self.idC])
    }

    @Test func preorderEmptyOrderIsEmpty() {
        #expect(SessionTree.preorder([]) == [])
    }

    // fixture roots are A (with subtree A/b/c, A/d) and E. Moving E up swaps the two ROOTS, carrying A's
    // whole subtree — a flat index move would strand E inside A's subtree and break contiguity.
    @Test func reorderSiblingRootUpCarriesTheNeighbourSubtree() {
        #expect(SessionTree.reorderSibling(Self.idE, .up, in: Self.fixture)
            == [Self.idE, Self.idA, Self.idB, Self.idC, Self.idD])
    }

    // b and d are both children of A; moving d up past b keeps A's subtree contiguous (d, d has no kids;
    // b carries c).
    @Test func reorderSiblingChildUpStaysWithinTheParentSubtree() {
        #expect(SessionTree.reorderSibling(Self.idD, .up, in: Self.fixture)
            == [Self.idA, Self.idD, Self.idB, Self.idC, Self.idE])
    }

    @Test func reorderSiblingChildToBottomIsAlreadyLastIsNil() {
        // d is already A's last child, so `bottom`/`down` are no-ops within the sibling group.
        #expect(SessionTree.reorderSibling(Self.idD, .bottom, in: Self.fixture) == nil)
        #expect(SessionTree.reorderSibling(Self.idD, .down, in: Self.fixture) == nil)
    }

    @Test func reorderSiblingRootToBottom() {
        #expect(SessionTree.reorderSibling(Self.idA, .bottom, in: Self.fixture)
            == [Self.idE, Self.idA, Self.idB, Self.idC, Self.idD])
    }

    @Test func reorderSiblingUnknownIDIsNil() {
        #expect(SessionTree.reorderSibling(UUID(), .up, in: Self.fixture) == nil)
    }
}
