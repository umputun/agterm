import Testing
@testable import agtermCore

struct ReorderTests {
    @Test func middleIndexUp() {
        #expect(ReorderDirection.up.destinationIndex(from: 2, count: 5) == 1)
    }

    @Test func middleIndexDown() {
        // the post-removal index lands the element after its old neighbor, so down from 2 is 3.
        #expect(ReorderDirection.down.destinationIndex(from: 2, count: 5) == 3)
    }

    @Test func middleIndexTop() {
        #expect(ReorderDirection.top.destinationIndex(from: 2, count: 5) == 0)
    }

    @Test func middleIndexBottom() {
        // count - 1 is the post-removal last index.
        #expect(ReorderDirection.bottom.destinationIndex(from: 2, count: 5) == 4)
    }

    @Test func upAtFirstIsNoOp() {
        #expect(ReorderDirection.up.destinationIndex(from: 0, count: 5) == nil)
    }

    @Test func topAtFirstIsNoOp() {
        #expect(ReorderDirection.top.destinationIndex(from: 0, count: 5) == nil)
    }

    @Test func downAtLastIsNoOp() {
        #expect(ReorderDirection.down.destinationIndex(from: 4, count: 5) == nil)
    }

    @Test func bottomAtLastIsNoOp() {
        #expect(ReorderDirection.bottom.destinationIndex(from: 4, count: 5) == nil)
    }

    @Test func singleElementAllNil() {
        #expect(ReorderDirection.up.destinationIndex(from: 0, count: 1) == nil)
        #expect(ReorderDirection.down.destinationIndex(from: 0, count: 1) == nil)
        #expect(ReorderDirection.top.destinationIndex(from: 0, count: 1) == nil)
        #expect(ReorderDirection.bottom.destinationIndex(from: 0, count: 1) == nil)
    }

    @Test func twoElementListFromFirst() {
        #expect(ReorderDirection.up.destinationIndex(from: 0, count: 2) == nil)
        #expect(ReorderDirection.top.destinationIndex(from: 0, count: 2) == nil)
        #expect(ReorderDirection.down.destinationIndex(from: 0, count: 2) == 1)
        #expect(ReorderDirection.bottom.destinationIndex(from: 0, count: 2) == 1)
    }

    @Test func twoElementListFromLast() {
        #expect(ReorderDirection.down.destinationIndex(from: 1, count: 2) == nil)
        #expect(ReorderDirection.bottom.destinationIndex(from: 1, count: 2) == nil)
        #expect(ReorderDirection.up.destinationIndex(from: 1, count: 2) == 0)
        #expect(ReorderDirection.top.destinationIndex(from: 1, count: 2) == 0)
    }

    @Test func rawValueRoundTrip() {
        #expect(ReorderDirection(rawValue: "up") == .up)
        #expect(ReorderDirection(rawValue: "down") == .down)
        #expect(ReorderDirection(rawValue: "top") == .top)
        #expect(ReorderDirection(rawValue: "bottom") == .bottom)
        #expect(ReorderDirection(rawValue: "sideways") == nil)
    }
}
