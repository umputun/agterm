import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlEventRingTests {
    private let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let fixedDate = Date(timeIntervalSince1970: 1_783_969_641.38)

    private func ring(capacity: Int = 4_096) -> ControlEventRing {
        ControlEventRing(capacity: capacity, runID: runID, now: { fixedDate })
    }

    private func draft(_ kind: ControlEventKind, name: String = "api-fix") -> ControlEventDraft {
        ControlEventDraft(
            kind: kind,
            window: "window",
            workspace: "workspace",
            session: "session",
            payload: ControlEventPayload(name: name)
        )
    }

    @Test func appendAssignsMonotonicSequenceAndTimestamp() {
        let subject = ring()

        let first = subject.append(draft(.status))
        let second = subject.append(draft(.notify))

        #expect(first.seq == 1)
        #expect(second.seq == 2)
        #expect(first.ts == fixedDate.timeIntervalSince1970)
        #expect(first.kind == .status)
        #expect(first.window == "window")
        #expect(first.payload.name == "api-fix")
    }

    @Test func bootstrapAnchorsAtTailWithoutReplayingHistory() {
        let subject = ring()
        subject.append(draft(.status))
        subject.append(draft(.notify))

        let result = subject.read(cursor: nil)

        #expect(result == .batch(ControlEventBatch(run: runID, next: 2, items: [])))
    }

    @Test func capacityEvictsOldestAndKeepsExactBoundaryReadable() {
        let subject = ring(capacity: 2)
        subject.append(draft(.status, name: "one"))
        subject.append(draft(.notify, name: "two"))
        subject.append(draft(.sessionCreated, name: "three"))

        let boundary = subject.read(cursor: ControlEventCursor(run: runID, after: 1))
        let expired = subject.read(cursor: ControlEventCursor(run: runID, after: 0))

        #expect(boundary == .batch(ControlEventBatch(run: runID, next: 3, items: [
            ControlEvent(seq: 2, ts: fixedDate.timeIntervalSince1970, draft: draft(.notify, name: "two")),
            ControlEvent(seq: 3, ts: fixedDate.timeIntervalSince1970, draft: draft(.sessionCreated, name: "three")),
        ])))
        #expect(expired == .failure(.cursorExpired, anchor: ControlEventBatch(run: runID, next: 3, items: [])))
    }

    @Test func readsAreNonDestructiveAndIndependent() {
        let subject = ring()
        subject.append(draft(.status))

        let cursor = ControlEventCursor(run: runID, after: 0)
        let first = subject.read(cursor: cursor)
        let second = subject.read(cursor: cursor)

        #expect(first == second)
        #expect(first.batch?.items.map(\.seq) == [1])
    }

    @Test func filterAdvancesAcrossNonmatchingEvents() {
        let subject = ring()
        subject.append(draft(.notify))
        subject.append(draft(.status))
        subject.append(draft(.sessionClosed))

        let result = subject.read(
            cursor: ControlEventCursor(run: runID, after: 0),
            kinds: [.status]
        )

        #expect(result.batch?.items.map(\.kind) == [.status])
        #expect(result.batch?.next == 3)
    }

    @Test func emptyFilteredBatchAdvancesToTail() {
        let subject = ring()
        subject.append(draft(.notify))
        subject.append(draft(.sessionClosed))

        let result = subject.read(
            cursor: ControlEventCursor(run: runID, after: 0),
            kinds: [.status]
        )

        #expect(result == .batch(ControlEventBatch(run: runID, next: 2, items: [])))
    }

    @Test func limitStopsAtLastReturnedMatchWithoutDroppingLaterMatches() {
        let subject = ring()
        subject.append(draft(.notify, name: "skip"))
        subject.append(draft(.status, name: "first"))
        subject.append(draft(.notify, name: "skip-two"))
        subject.append(draft(.status, name: "second"))

        let first = subject.read(
            cursor: ControlEventCursor(run: runID, after: 0),
            kinds: [.status],
            limit: 1
        )
        let second = subject.read(
            cursor: ControlEventCursor(run: runID, after: first.batch!.next),
            kinds: [.status],
            limit: 1
        )

        #expect(first.batch?.next == 2)
        #expect(first.batch?.items.map(\.payload.name) == ["first"])
        #expect(second.batch?.next == 4)
        #expect(second.batch?.items.map(\.payload.name) == ["second"])
    }

    @Test func runMismatchReturnsCurrentAnchor() {
        let subject = ring()
        subject.append(draft(.status))
        let otherRun = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let result = subject.read(cursor: ControlEventCursor(run: otherRun, after: 0))

        #expect(result == .failure(.runChanged, anchor: ControlEventBatch(run: runID, next: 1, items: [])))
    }

    @Test func cursorAheadReturnsCurrentAnchor() {
        let subject = ring()
        subject.append(draft(.status))

        let result = subject.read(cursor: ControlEventCursor(run: runID, after: 2))

        #expect(result == .failure(.cursorAhead, anchor: ControlEventBatch(run: runID, next: 1, items: [])))
    }
}

private extension ControlEventReadResult {
    var batch: ControlEventBatch? {
        guard case .batch(let batch) = self else { return nil }
        return batch
    }
}
