import Foundation
import Testing
@testable import agtermCore

@MainActor
struct RemoteRespawnTests {
    private let pane = UUID()
    private let session = UUID()
    private func mark(_ generation: Int, epoch: String = "e1") -> RemoteRespawnBook.Mark {
        RemoteRespawnBook.Mark(epoch: epoch, generation: generation)
    }

    private func observe(_ book: RemoteRespawnBook, _ generation: Int, epoch: String = "e1", seed: Bool = false,
                         pane: UUID? = nil) -> Bool {
        book.observe(mark(generation, epoch: epoch), pane: pane ?? self.pane, session: session, seed: seed)
    }

    private func held(_ book: RemoteRespawnBook, pane: UUID? = nil) -> Bool {
        book.held(pane: pane ?? self.pane, session: session)
    }

    @Test func aCleanExitWithNoRespawnKeepsThePrompt() {
        let book = RemoteRespawnBook()
        #expect(!observe(book, 0, seed: true))
        #expect(!held(book))
    }

    @Test func aRespawnBeforeOrAfterTheHeldExitReattaches() {
        let before = RemoteRespawnBook()
        _ = observe(before, 0, seed: true)
        #expect(!observe(before, 1))
        #expect(held(before))

        let after = RemoteRespawnBook()
        _ = observe(after, 0, seed: true)
        #expect(!held(after))
        #expect(observe(after, 1))
    }

    @Test func aReconnectSnapshotRecoversAMissedRespawnFrame() {
        let book = RemoteRespawnBook()
        _ = observe(book, 2, seed: true)
        #expect(!held(book))
        #expect(observe(book, 3, seed: true), "a later snapshot is compared, never taken as a new baseline")
    }

    @Test func anOriginRestartIsNeverReadAsOlder() {
        let book = RemoteRespawnBook()
        _ = observe(book, 5, epoch: "old", seed: true)
        _ = held(book)
        #expect(!observe(book, 0, epoch: "new", seed: true))
        #expect(observe(book, 1, epoch: "new"))
    }

    @Test func twoLocalViewsOfOneOriginPaneReattachIndependently() {
        let book = RemoteRespawnBook()
        let other = UUID()
        for local in [pane, other] {
            _ = observe(book, 0, seed: true, pane: local)
            _ = held(book, pane: local)
        }
        #expect(observe(book, 1))
        book.attachStarted(pane: pane, session: session)
        book.acknowledged(pane: pane)
        #expect(observe(book, 1, pane: other), "the first view consuming it leaves the second due")
    }

    @Test func aGenerationIsConsumedOnlyByAnAcknowledgedAttachAndFailuresAreBounded() {
        let book = RemoteRespawnBook()
        _ = observe(book, 0, seed: true)
        _ = observe(book, 1)
        #expect(held(book))

        for _ in 1..<RemoteRespawnBook.maxAttempts {
            book.attachStarted(pane: pane, session: session)
            #expect(held(book), "an attach that exits before reporting retries the same generation")
        }
        book.attachStarted(pane: pane, session: session)
        #expect(!held(book), "the attempts for one generation are bounded")
        #expect(observe(book, 2), "a newer respawn starts a fresh budget")
        book.attachStarted(pane: pane, session: session)
        book.acknowledged(pane: pane)
        #expect(!held(book))
    }

    // the acknowledgement once consumed the newest mark, skipping a respawn that arrived during the attach
    @Test func anAcknowledgementConsumesOnlyTheGenerationItsAttachStartedFor() {
        let book = RemoteRespawnBook()
        _ = observe(book, 0, seed: true)
        _ = observe(book, 1)
        _ = held(book)
        book.attachStarted(pane: pane, session: session)
        #expect(!observe(book, 2), "an attach in flight is not started twice")
        book.acknowledged(pane: pane)
        #expect(held(book), "respawn 2 is still owed after the attach for 1 reported")
    }

    @Test func aFailureOfAnOlderAttachIsNotChargedToANewerGeneration() {
        let book = RemoteRespawnBook()
        _ = observe(book, 0, seed: true)
        _ = observe(book, 1)
        _ = held(book)
        for _ in 1..<RemoteRespawnBook.maxAttempts {
            book.attachStarted(pane: pane, session: session)
            _ = held(book)
        }
        book.attachStarted(pane: pane, session: session)
        _ = observe(book, 2)
        #expect(held(book), "the last attempt for 1 failing leaves 2 with its whole budget")
    }

    // an ordinary network reconnect's report was ignored, so a later clean exit replayed a consumed respawn
    @Test func aNetworkReconnectsAcknowledgementAlsoMovesTheBaseline() {
        let book = RemoteRespawnBook()
        _ = observe(book, 0, seed: true)
        _ = observe(book, 1)
        book.attachStarted(pane: pane, session: session)
        book.acknowledged(pane: pane)
        #expect(!held(book), "a clean exit with no new respawn keeps the prompt")
    }

    @Test func theHeldFactOutlivesAnyStreamOutageUntilPruned() {
        let book = RemoteRespawnBook()
        _ = observe(book, 0, seed: true)
        _ = held(book)
        #expect(observe(book, 1, seed: true), "no clock: a snapshot after a long outage still reattaches")
        book.prune { _, _ in false }
        #expect(book.entries.isEmpty)
    }

    @Test func theRespawnFrameAndSnapshotRoundTripAndAnOlderSnapshotHasNone() throws {
        let respawns = PresentationRespawns(epoch: "e1", generations: ["agterm-a": 2])
        let frame = PresentationFrame(gen: 1, rev: 3, body: .respawn(respawns))
        #expect(try PresentationCodec.decode(PresentationCodec.encode(frame)) == frame)
        let snapshot = PresentationSnapshot(status: nil, hud: nil, respawns: respawns)
        #expect(try JSONDecoder().decode(PresentationSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        let older = try JSONDecoder().decode(PresentationSnapshot.self, from: Data("{}".utf8))
        #expect(older.respawns == nil)
    }
}
