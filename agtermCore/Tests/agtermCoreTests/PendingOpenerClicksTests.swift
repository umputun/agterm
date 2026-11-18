import Foundation
import Testing
@testable import agtermCore

@MainActor
struct PendingOpenerClicksTests {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_789_000_000) }

    private let clock = Clock()
    private let connection = UUID()
    private let session = UUID()
    private let pane = UUID()

    private func rules(_ text: String) -> [FileOpener] {
        let (keymap, diagnostics) = parseKeymap(text)
        #expect(diagnostics.isEmpty)
        return keymap.openers
    }

    private func book() -> PendingOpenerClicks {
        let clock = clock
        return PendingOpenerClicks(now: { clock.now })
    }

    private func record(_ raw: String, in book: PendingOpenerClicks, rules: [FileOpener]) -> UUID? {
        book.record(raw: raw, connection: connection, session: session, pane: pane, rules: rules)
    }

    private func snapshot(_ click: UUID, name: String) -> PresentationLinkSnapshot {
        PresentationLinkSnapshot(click: click, token: "tok", name: name, size: 1)
    }

    @Test func aClickNoRuleCouldTakeIsNotRecorded() {
        let book = book()

        #expect(record("src/main.go", in: book, rules: rules("open *.md view")) == nil)
        #expect(record("https://example.com/a.md", in: book, rules: rules("open *.md view")) == nil)
        #expect(book.isEmpty)
    }

    @Test func aRecordedClickSendsOnlyTheSelectorsItsCandidatesMatch() throws {
        let book = book()
        let click = try #require(record("src/Makefile:3", in: book, rules: rules("""
            open *.md,Makefile view-make
            open *.go view-go
            """)))

        #expect(book.selectors(for: click) == ["Makefile"])
    }

    @Test func theResolvedNamePicksItsRuleFromTheClickTimeRules() throws {
        let book = book()
        let set = rules("""
            open *.swift view-swift
            open file.swift view-one
            open Makefile view-make
            """)
        let make = try #require(record("src/Makefile:3", in: book, rules: set))
        let one = try #require(record("src/file.swift:3", in: book, rules: set))

        #expect(book.accept(snapshot(make, name: "Makefile"), connection: connection, session: session)?.rule.command.command
            == "view-make")
        #expect(book.accept(snapshot(one, name: "file.swift"), connection: connection, session: session)?.rule.command.command
            == "view-one")
    }

    @Test func aSnapshotIsTakenOnceAndOnlyForItsOwnConnectionSessionAndCandidates() throws {
        let book = book()
        let click = try #require(record("/srv/notes.md", in: book, rules: rules("open *.md view")))

        #expect(book.accept(snapshot(UUID(), name: "notes.md"), connection: connection, session: session) == nil)
        #expect(book.accept(snapshot(click, name: "notes.md"), connection: UUID(), session: session) == nil)
        #expect(book.accept(snapshot(click, name: "notes.md"), connection: connection, session: UUID()) == nil)
        #expect(book.accept(snapshot(click, name: "other.md"), connection: connection, session: session) == nil)
        let accepted = try #require(book.accept(snapshot(click, name: "notes.md"), connection: connection, session: session))
        #expect(accepted.entry.pane == pane)
        #expect(book.accept(snapshot(click, name: "notes.md"), connection: connection, session: session) == nil)
        #expect(book.isCurrent(click, connection: connection))
    }

    @Test func anOfferArrivingAfterTheClaimWindowIsRejectedAndTheEntryDropped() throws {
        let book = book()
        let click = try #require(record("/srv/notes.md", in: book, rules: rules("open *.md view")))

        clock.now = clock.now.addingTimeInterval(PendingOpenerClicks.window + 1)

        #expect(book.accept(snapshot(click, name: "notes.md"), connection: connection, session: session) == nil)
        #expect(!book.isCurrent(click, connection: connection))
        #expect(book.isEmpty)
    }

    @Test func expiryLeavesAClickWhoseTransferIsInFlight() throws {
        let book = book()
        let click = try #require(record("/srv/notes.md", in: book, rules: rules("open *.md view")))
        #expect(book.accept(snapshot(click, name: "notes.md"), connection: connection, session: session) != nil)

        clock.now = clock.now.addingTimeInterval(PendingOpenerClicks.window + 1)
        book.expire()

        #expect(book.isCurrent(click, connection: connection))
    }

    @Test func aRefusalOrTheSpawnRetiresTheClick() throws {
        let book = book()
        let refused = try #require(record("/srv/a.md", in: book, rules: rules("open *.md view")))
        let spawned = try #require(record("/srv/b.md", in: book, rules: rules("open *.md view")))
        #expect(book.accept(snapshot(spawned, name: "b.md"), connection: connection, session: session) != nil)

        #expect(book.retire(refused) != nil)
        #expect(book.retire(spawned) != nil)

        #expect(book.accept(snapshot(refused, name: "a.md"), connection: connection, session: session) == nil)
        #expect(!book.isCurrent(spawned, connection: connection))
        #expect(book.retire(spawned) == nil)
    }

    @Test func teardownRetiresEveryClickOfThatConnectionOnly() throws {
        let book = book()
        let pending = try #require(record("/srv/a.md", in: book, rules: rules("open *.md view")))
        let inFlight = try #require(record("/srv/b.md", in: book, rules: rules("open *.md view")))
        #expect(book.accept(snapshot(inFlight, name: "b.md"), connection: connection, session: session) != nil)
        let other = try #require(book.record(raw: "/srv/c.md", connection: UUID(), session: session, pane: pane,
                                             rules: rules("open *.md view")))

        let removed = book.teardown(connection: connection)

        #expect(Set(removed.map(\.click)) == [pending, inFlight])
        #expect(removed.first { $0.click == inFlight }?.inFlight == true)
        #expect(book.accept(snapshot(pending, name: "a.md"), connection: connection, session: session) == nil)
        #expect(!book.isCurrent(inFlight, connection: connection))
        #expect(book.retire(other) != nil)
    }
}
