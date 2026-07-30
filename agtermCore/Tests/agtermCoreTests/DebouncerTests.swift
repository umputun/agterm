import Testing
@testable import agtermCore

@MainActor
struct DebouncerTests {
    @Test func flushRunsOnlyLatestActionOnce() {
        let debouncer = Debouncer()
        var first = 0
        var second = 0
        // a long delay so the async dispatch can't fire before flush; flush is what runs it.
        debouncer.schedule(after: 100) { first += 1 }
        debouncer.schedule(after: 100) { second += 1 }
        debouncer.flush()
        #expect(first == 0)
        #expect(second == 1)
    }

    @Test func cancelDropsPendingAction() {
        let debouncer = Debouncer()
        var ran = 0
        debouncer.schedule(after: 100) { ran += 1 }
        debouncer.cancel()
        debouncer.flush()
        #expect(ran == 0)
    }

    @Test func flushWithNothingPendingIsNoOp() {
        let debouncer = Debouncer()
        debouncer.flush()
        var ran = 0
        debouncer.schedule(after: 100) { ran += 1 }
        debouncer.flush()
        debouncer.flush()
        #expect(ran == 1)
    }

    @Test func scheduledActionFiresWhenTimerElapses() async {
        // the other tests use a 100s delay plus flush, so only here does the timer itself fire.
        let debouncer = Debouncer()
        await confirmation { confirmed in
            debouncer.schedule(after: 0.01) { confirmed() }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    @Test func reschedulingBeforeTimerFiresRunsOnlyLatestViaTimer() async {
        let debouncer = Debouncer()
        var first = 0
        await confirmation { confirmedLatest in
            debouncer.schedule(after: 0.01) { first += 1 }
            debouncer.schedule(after: 0.01) { confirmedLatest() }
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(first == 0)
    }

    @Test func actionCallingFlushReentrantlyIsSafeNoOp() {
        // fire() clears `action` before invoking it, so an action that re-entrantly flush()es is a no-op
        // rather than recursing or running twice.
        let debouncer = Debouncer()
        var ran = 0
        debouncer.schedule(after: 100) {
            ran += 1
            debouncer.flush()
        }
        debouncer.flush()
        #expect(ran == 1)
    }
}
