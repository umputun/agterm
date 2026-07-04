import Testing
@testable import agtermCore

struct RecencyStackTests {
    @Test func pushMovesToFrontWithoutDuplicating() {
        var stack = RecencyStack<Int>()
        stack.push(1); stack.push(2); stack.push(3)
        #expect(stack.items == [3, 2, 1])
        stack.push(1) // existing id moves to front, no duplicate
        #expect(stack.items == [1, 3, 2])
    }

    @Test func pushSameFrontIsNoOp() {
        var stack = RecencyStack<Int>()
        stack.push(1)
        stack.push(1)
        #expect(stack.items == [1])
    }

    @Test func removeDropsId() {
        var stack = RecencyStack<Int>(items: [3, 2, 1])
        stack.remove(2)
        #expect(stack.items == [3, 1])
    }

    @Test func initDropsDuplicateSeedIds() {
        // a persisted/hand-edited seed may carry duplicates; the first occurrence wins.
        let stack = RecencyStack<Int>(items: [1, 2, 1, 3, 2])
        #expect(stack.items == [1, 2, 3])
    }

    @Test func initDedupsBeforeTruncatingToLimit() {
        // dedup must run before the limit cut: prefix-then-dedup would yield [1] here.
        let stack = RecencyStack<Int>(limit: 2, items: [1, 1, 2, 3])
        #expect(stack.items == [1, 2])
    }

    @Test func limitBoundsTheList() {
        var stack = RecencyStack<Int>(limit: 2)
        stack.push(1); stack.push(2); stack.push(3)
        #expect(stack.items == [3, 2])
    }

    @Test func topReturnsRecentValidIdsSkippingStale() {
        let stack = RecencyStack<Int>(items: [4, 3, 2, 1])
        // 3 is stale (not in valid); it's skipped, the rest stay most-recent-first.
        #expect(stack.top(2, in: [1, 2, 4]) == [4, 2])
        #expect(stack.top(10, in: [1, 2, 4]) == [4, 2, 1])
    }

    @Test func topCapsResultAtRequestedCount() {
        // the Ctrl-Tab switcher feeds top() its 10-item display cap; with more valid ids than the cap,
        // top returns exactly n, most-recent-first, and drops the oldest beyond it.
        var stack = RecencyStack<Int>()
        for i in 1...12 { stack.push(i) }
        let capped = stack.top(10, in: Set(1...12))
        #expect(capped.count == 10)
        #expect(capped == [12, 11, 10, 9, 8, 7, 6, 5, 4, 3])
    }
}
