import Foundation
import Testing
@testable import agtermCore

@MainActor
private final class KindCollector {
    var kinds: [ControlEventKind] = []
}

@MainActor
struct AppStoreFlaggedOrderTests {
    private func sessions(_ store: AppStore, _ names: [String], in name: String = "work") throws -> [Session] {
        let ws = store.addWorkspace(name: name)
        return try names.map { try #require(store.addSession(toWorkspace: ws.id, cwd: "/\($0)")) }
    }

    private func order(_ store: AppStore) -> [UUID] { store.orderedFlaggedSessions.map(\.id) }

    private func flagged(_ names: [String], order flagOrder: [Int]) throws -> (AppStore, [Session]) {
        let store = makeStore()
        let all = try sessions(store, names)
        for index in flagOrder { store.setFlag(true, forSession: all[index].id) }
        return (store, all)
    }

    @Test func flaggingAppendsAndUnflaggingRemoves() throws {
        let (store, s) = try flagged(["a", "b", "c"], order: [0, 2, 1])
        #expect(store.flaggedOrder == [s[0].id, s[2].id, s[1].id])
        #expect(order(store) == [s[0].id, s[2].id, s[1].id])
        #expect(store.flaggedSessions.map(\.id) == [s[0].id, s[1].id, s[2].id])

        store.setFlag(false, forSession: s[2].id)

        #expect(store.flaggedOrder == [s[0].id, s[1].id])
    }

    @Test func flagAllKeepsArrangedPositionsAndAppendsTheRestInTreeOrder() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let s = try ["a", "b", "c", "d"].map { try #require(store.addSession(toWorkspace: ws.id, cwd: "/\($0)")) }
        store.setFlag(true, forSession: s[2].id)
        store.setFlag(true, forSession: s[0].id)

        store.applyWorkspaceFlag(.on, to: ws.id)

        #expect(store.flaggedOrder == [s[2].id, s[0].id, s[1].id, s[3].id])
    }

    @Test func flaggingAnAlreadyFlaggedSessionChangesNothing() throws {
        let (store, s) = try flagged(["a", "b"], order: [1, 0])

        store.setFlag(true, forSession: s[1].id)
        store.setFlag(true, forSessions: [s[0].id, s[1].id])

        #expect(store.flaggedOrder == [s[1].id, s[0].id])
    }

    @Test func clearFlaggedEmptiesTheOrder() throws {
        let (store, _) = try flagged(["a", "b"], order: [0, 1])

        store.clearFlags()

        #expect(store.flaggedOrder.isEmpty)
        #expect(store.orderedFlaggedSessions.isEmpty)
    }

    @Test(arguments: [
        (moving: [3], placement: FlaggedOrderPlacement.before, anchor: 0, want: [3, 0, 1, 2]),
        (moving: [0], placement: FlaggedOrderPlacement.after, anchor: 2, want: [1, 2, 0, 3]),
        (moving: [2, 0], placement: FlaggedOrderPlacement.after, anchor: 3, want: [1, 3, 0, 2]),
        (moving: [1, 2], placement: FlaggedOrderPlacement.before, anchor: 0, want: [1, 2, 0, 3]),
    ])
    func moveRearrangesTheBlockInItsCurrentOrder(moving: [Int], placement: FlaggedOrderPlacement, anchor: Int,
                                                 want: [Int]) throws {
        let (store, s) = try flagged(["a", "b", "c", "d"], order: [0, 1, 2, 3])

        #expect(store.moveFlagged(moving.map { s[$0].id }, to: placement, of: s[anchor].id))

        #expect(order(store) == want.map { s[$0].id })
    }

    @Test func moveThatLeavesTheOrderUnchangedIsANoOp() throws {
        let (store, s) = try flagged(["a", "b", "c"], order: [0, 1, 2])

        #expect(!store.moveFlagged([s[1].id], to: .after, of: s[0].id))
        #expect(!store.moveFlagged([s[0].id], to: .before, of: s[1].id))
        #expect(order(store) == s.map(\.id))
    }

    @Test func moveRefusesTheAnchorInTheBlockAndIdsOutsideTheFlaggedSet() throws {
        let store = makeStore()
        let s = try sessions(store, ["a", "b", "c"])
        store.setFlag(true, forSession: s[0].id)
        store.setFlag(true, forSession: s[1].id)

        #expect(!store.moveFlagged([s[0].id], to: .before, of: s[0].id))
        #expect(!store.moveFlagged([s[2].id], to: .before, of: s[0].id))
        #expect(!store.moveFlagged([s[0].id], to: .after, of: s[2].id))
        #expect(!store.moveFlagged([UUID()], to: .after, of: s[1].id))
        #expect(!store.moveFlagged([], to: .after, of: s[1].id))
        #expect(order(store) == [s[0].id, s[1].id])
    }

    @Test func moveSignalsATreeChangeOnlyWhenTheOrderChanges() throws {
        let events = KindCollector()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir), controlEventSink: { events.kinds.append($0.kind) })
        let s = try sessions(store, ["a", "b"])
        store.setFlag(true, forSession: s[0].id)
        store.setFlag(true, forSession: s[1].id)
        events.kinds.removeAll()

        store.moveFlagged([s[0].id], to: .before, of: s[1].id)
        #expect(events.kinds.isEmpty)

        store.moveFlagged([s[1].id], to: .before, of: s[0].id)
        #expect(events.kinds == [.treeChanged])
    }

    @Test func moveKeepsAParkedPendingCloseInItsSlotSoUndoReturnsItInPlace() throws {
        let (store, s) = try flagged(["a", "b", "c"], order: [0, 1, 2])
        defer { store.finalizeAllPendingCloses() }
        #expect(store.softCloseSession(s[1].id, grace: 60))
        #expect(order(store) == [s[0].id, s[2].id])

        #expect(store.moveFlagged([s[2].id], to: .before, of: s[0].id))
        #expect(store.flaggedOrder == [s[2].id, s[1].id, s[0].id])

        #expect(store.undoPendingClose())
        #expect(order(store) == [s[2].id, s[1].id, s[0].id])
    }

    @Test func finalizingAPendingCloseDropsItFromTheOrder() throws {
        let (store, s) = try flagged(["a", "b"], order: [0, 1])
        #expect(store.softCloseSession(s[0].id, grace: 60))

        store.finalizeAllPendingCloses()

        #expect(store.flaggedOrder == [s[1].id])
    }

    @Test func undoAfterClearFlaggedAppendsTheReturningSession() throws {
        let (store, s) = try flagged(["a", "b", "c"], order: [0, 1])
        defer { store.finalizeAllPendingCloses() }
        #expect(store.softCloseSession(s[0].id, grace: 60))
        store.clearFlags()
        store.setFlag(true, forSession: s[2].id)

        #expect(store.undoPendingClose())

        #expect(order(store) == [s[2].id, s[0].id])
    }

    @Test func reopenedSessionsAppendInArrivalOrderNotTreeOrder() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let s = try sessions(store, ["a", "b", "c"])
        for session in s { store.setFlag(true, forSession: session.id) }
        store.closeSession(s[0].id)
        store.closeSession(s[1].id)
        #expect(store.flaggedOrder == [s[2].id])

        for id in [s[1].id, s[0].id] {
            let item = try #require(recentClosed.load().first { $0.session?.snapshot.id == id })
            #expect(store.restoreRecentClosed(item))
        }

        #expect(store.workspaces.flatMap(\.sessions).map(\.id) == s.map(\.id))
        #expect(order(store) == [s[2].id, s[1].id, s[0].id])
    }

    @Test func aFlagAfterAReopenLandsAfterTheReopenedSession() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let s = try sessions(store, ["b", "c", "d"])
        store.setFlag(true, forSession: s[0].id)
        store.setFlag(true, forSession: s[1].id)
        store.closeSession(s[0].id)
        let item = try #require(recentClosed.load().first { $0.session?.snapshot.id == s[0].id })
        #expect(store.restoreRecentClosed(item))

        store.setFlag(true, forSession: s[2].id)

        #expect(order(store) == [s[1].id, s[0].id, s[2].id])
    }

    @Test func hardClosedThenReopenedSessionAppends() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let s = try sessions(store, ["a", "b", "c"])
        for session in s { store.setFlag(true, forSession: session.id) }
        store.closeSession(s[1].id)
        #expect(store.flaggedOrder == [s[0].id, s[2].id])

        let item = try #require(recentClosed.load().first { $0.session?.snapshot.id == s[1].id })
        #expect(store.restoreRecentClosed(item))

        #expect(order(store) == [s[0].id, s[2].id, s[1].id])
    }

    @Test func deletedThenReopenedWorkspaceAppendsItsFlaggedSessions() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let kept = try sessions(store, ["a"], in: "kept")
        let gone = try sessions(store, ["x", "y"], in: "gone")
        store.setFlag(true, forSession: gone[0].id)
        store.setFlag(true, forSession: kept[0].id)
        store.setFlag(true, forSession: gone[1].id)
        let goneID = try #require(store.workspace(forSession: gone[0].id)?.id)

        store.removeWorkspace(goneID)
        #expect(store.flaggedOrder == [kept[0].id])

        let item = try #require(recentClosed.load().first { $0.kind == .workspace })
        #expect(store.restoreRecentClosed(item))

        #expect(order(store) == [kept[0].id, gone[0].id, gone[1].id])
    }

    @Test func reopeningIntoAnotherWindowAppendsToThatWindowsOrder() throws {
        let (first, recentClosed, _) = makeStoreWithRecentClosed()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let second = AppStore(persistence: PersistenceStore(directory: dir), recentClosedStore: recentClosed)
        let moved = try sessions(first, ["a"])
        let resident = try sessions(second, ["z"])
        first.setFlag(true, forSession: moved[0].id)
        second.setFlag(true, forSession: resident[0].id)
        first.closeSession(moved[0].id)

        let item = try #require(recentClosed.load().first { $0.session?.snapshot.id == moved[0].id })
        #expect(second.restoreRecentClosed(item))

        #expect(order(second) == [resident[0].id, moved[0].id])
    }

    @Test func savedOrderSurvivesASnapshotRoundTrip() throws {
        let (store, s) = try flagged(["a", "b", "c"], order: [2, 0])

        let data = try JSONEncoder().encode(store.snapshot())
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        let restored = makeStore()
        restored.restore(from: decoded)

        #expect(decoded.flaggedOrder == [s[2].id, s[0].id])
        #expect(restored.orderedFlaggedSessions.map(\.id) == [s[2].id, s[0].id])
    }

    @Test func snapshotWithoutTheOrderRestoresInTreeOrder() throws {
        let (store, s) = try flagged(["a", "b", "c"], order: [2, 0])
        var snapshot = store.snapshot()
        snapshot.flaggedOrder = nil

        let restored = makeStore()
        restored.restore(from: snapshot)

        #expect(restored.flaggedOrder == [s[0].id, s[2].id])
    }

    @Test func restoreDropsUnknownUnflaggedAndRepeatedIdsAndAppendsMissingFlaggedOnes() throws {
        let (store, s) = try flagged(["a", "b", "c", "d"], order: [3, 0, 2])
        var snapshot = store.snapshot()
        snapshot.flaggedOrder = [s[2].id, UUID(), s[1].id, s[2].id, s[3].id]

        let restored = makeStore()
        restored.restore(from: snapshot)

        #expect(restored.flaggedOrder == [s[2].id, s[3].id, s[0].id])
    }

    @Test func snapshotOmitsTheOrderWhenNothingIsFlagged() throws {
        let store = makeStore()
        _ = try sessions(store, ["a"])

        #expect(store.snapshot().flaggedOrder == nil)
    }
}
