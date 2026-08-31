import Foundation
import Testing
@testable import agtermCore

struct ZmxInventoryTests {
    private static let paneA = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
    private static let paneB = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
    private static let windowID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c0")!
    private static let sessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000d0")!

    private static var nameA: String { ZmxSupport.daemonName(for: paneA) }
    private static var nameB: String { ZmxSupport.daemonName(for: paneB) }

    private static func claim(_ paneIdentity: UUID, pane: ZmxPaneRole = .left,
                              windowState: ZmxOwnerWindowState = .open,
                              pendingClose: Bool = false,
                              sessionID: UUID = ZmxInventoryTests.sessionID) -> ZmxPaneClaim {
        ZmxPaneClaim(paneIdentity: paneIdentity, pane: pane, pendingClose: pendingClose,
                     windowID: windowID, windowName: "window 1", windowState: windowState,
                     workspaceID: nil, workspaceName: "default",
                     sessionID: sessionID, sessionName: "build")
    }

    private static func row(_ result: ZmxInventoryResult, _ daemon: String) throws -> ZmxInventoryRow {
        try #require(result.rows.first { $0.daemon == daemon })
    }

    @Test func claimedDaemonCarriesItsOwnerAndClientCount() throws {
        let observed = [ZmxSessionRecord(name: Self.nameA, clients: 1, leaderPID: 42)]
        let result = ZmxInventory.join(observed: observed, claims: [Self.claim(Self.paneA)],
                                       inventoryComplete: true)
        let row = try Self.row(result, Self.nameA)
        #expect(row.state == .claimed)
        #expect(row.observation == .running)
        #expect(row.clients == 1)
        #expect(row.leaderPID == 42)
        #expect(row.claim?.sessionName == "build")
    }

    @Test func unmatchedDaemonIsOrphanOnlyWhenTheInventoryIsComplete() throws {
        let observed = [ZmxSessionRecord(name: Self.nameA, clients: 0, leaderPID: 42)]
        let complete = ZmxInventory.join(observed: observed, claims: [], inventoryComplete: true)
        #expect(try Self.row(complete, Self.nameA).state == .orphan)

        let partial = ZmxInventory.join(observed: observed, claims: [], inventoryComplete: false)
        #expect(try Self.row(partial, Self.nameA).state == .unknown)
    }

    @Test func closedWindowClaimWithNoClientsStaysClaimed() throws {
        let observed = [ZmxSessionRecord(name: Self.nameA, clients: 0, leaderPID: 42)]
        let result = ZmxInventory.join(observed: observed,
                                       claims: [Self.claim(Self.paneA, windowState: .closed)],
                                       inventoryComplete: true)
        let row = try Self.row(result, Self.nameA)
        #expect(row.state == .claimed)
        #expect(row.clients == 0)
        #expect(row.claim?.windowState == .closed)
    }

    @Test func softClosedPaneReportsPendingCloseRatherThanAnOrphan() throws {
        let observed = [ZmxSessionRecord(name: Self.nameA, clients: 1, leaderPID: 42)]
        let result = ZmxInventory.join(observed: observed,
                                       claims: [Self.claim(Self.paneA, pendingClose: true)],
                                       inventoryComplete: true)
        #expect(try Self.row(result, Self.nameA).state == .pendingClose)
    }

    @Test func unreadableRowIsDistinctFromAnAbsentDaemon() throws {
        let observed = [ZmxSessionRecord(name: Self.nameA, clients: nil, leaderPID: nil)]
        let result = ZmxInventory.join(observed: observed,
                                       claims: [Self.claim(Self.paneA), Self.claim(Self.paneB, pane: .right)],
                                       inventoryComplete: true)

        let unreadable = try Self.row(result, Self.nameA)
        #expect(unreadable.observation == .unreadable)
        #expect(unreadable.clients == nil)

        let absent = try Self.row(result, Self.nameB)
        #expect(absent.observation == .absent)
        #expect(absent.state == .claimed)
        #expect(absent.clients == nil)
    }

    @Test func duplicatePaneIdentityConflictsEveryRowInsteadOfPickingAnOwner() throws {
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000d1")!
        let observed = [ZmxSessionRecord(name: Self.nameA, clients: 0, leaderPID: 42)]
        let result = ZmxInventory.join(
            observed: observed,
            claims: [Self.claim(Self.paneA), Self.claim(Self.paneA, pane: .right, sessionID: other)],
            inventoryComplete: true)

        let rows = result.rows.filter { $0.daemon == Self.nameA }
        #expect(rows.count == 1)
        #expect(rows.first?.state == .conflicted)
        #expect(rows.first?.claim == nil)
        #expect(!result.inventoryComplete)
    }

    @Test func unindexedWindowClaimCarriesNoWindowName() throws {
        let claim = ZmxPaneClaim(paneIdentity: Self.paneA, pane: .left, pendingClose: false,
                                 windowID: Self.windowID, windowName: nil, windowState: .unindexed,
                                 workspaceID: nil, workspaceName: "default",
                                 sessionID: Self.sessionID, sessionName: "build")
        let observed = [ZmxSessionRecord(name: Self.nameA, clients: 0, leaderPID: 42)]
        let result = ZmxInventory.join(observed: observed, claims: [claim], inventoryComplete: true)
        let row = try Self.row(result, Self.nameA)
        #expect(row.state == .claimed)
        #expect(row.claim?.windowName == nil)
        #expect(row.claim?.windowState == .unindexed)
    }

    @Test(arguments: [
        "agterm-not-ours",
        "agterm-",
        "agterm-00112233445566778899aabbccddeef",
        "agterm-00112233445566778899aabbccddeeff0",
        "agterm-00112233445566778899AABBCCDDEEFF",
        "agterm-00112233-4455-6677-8899-aabbccddeeff",
        "agterm-" + String(repeating: "\u{FF19}", count: 32),
    ])
    func userDaemonsMerelyStartingWithThePrefixAreForeignNotOrphans(name: String) throws {
        // a prefix test would make `agterm-notes` an orphan and prune would kill the user's own session
        let result = ZmxInventory.join(observed: [ZmxSessionRecord(name: name, clients: 0, leaderPID: 7)],
                                       claims: [], inventoryComplete: true)
        #expect(try Self.row(result, name).state == .foreign)
        #expect(ZmxPrunePolicy.namesToPrune(result) == [])
    }

    @Test func nonAppDaemonsAreReportedAsForeign() throws {
        let observed = [ZmxSessionRecord(name: "notes", clients: 0, leaderPID: 7)]
        let result = ZmxInventory.join(observed: observed, claims: [], inventoryComplete: true)
        let row = try Self.row(result, "notes")
        #expect(row.state == .foreign)
        #expect(row.claim == nil)
    }

    @Test func pruneTakesOnlyUnmatchedDetachedAppDaemons() {
        let observed = [
            ZmxSessionRecord(name: Self.nameA, clients: 0, leaderPID: 42),
            ZmxSessionRecord(name: Self.nameB, clients: 0, leaderPID: 43),
            ZmxSessionRecord(name: "notes", clients: 0, leaderPID: 7),
        ]
        let result = ZmxInventory.join(observed: observed, claims: [Self.claim(Self.paneB, pane: .right)],
                                       inventoryComplete: true)
        #expect(ZmxPrunePolicy.namesToPrune(result) == [Self.nameA])
    }

    @Test func pruneRefusesAnIncompleteInventoryRatherThanGuessing() {
        let observed = [ZmxSessionRecord(name: Self.nameA, clients: 0, leaderPID: 42)]
        let result = ZmxInventory.join(observed: observed, claims: [], inventoryComplete: false)
        #expect(ZmxPrunePolicy.namesToPrune(result) == nil)
    }

    @Test func pruneRefusesWhileAnyOwnershipIsConflicted() {
        let orphan = UUID(uuidString: "00000000-0000-0000-0000-0000000000ee")!
        let observed = [
            ZmxSessionRecord(name: Self.nameA, clients: 0, leaderPID: 42),
            ZmxSessionRecord(name: ZmxSupport.daemonName(for: orphan), clients: 0, leaderPID: 44),
        ]
        let result = ZmxInventory.join(
            observed: observed,
            claims: [Self.claim(Self.paneA), Self.claim(Self.paneA, pane: .right)],
            inventoryComplete: true)
        #expect(ZmxPrunePolicy.namesToPrune(result) == nil)
    }

    @Test func pruneLeavesAttachedAndUnreadableOrphansAlone() {
        let attached = UUID(uuidString: "00000000-0000-0000-0000-0000000000f1")!
        let unreadable = UUID(uuidString: "00000000-0000-0000-0000-0000000000f2")!
        let observed = [
            ZmxSessionRecord(name: ZmxSupport.daemonName(for: attached), clients: 2, leaderPID: 45),
            ZmxSessionRecord(name: ZmxSupport.daemonName(for: unreadable), clients: nil, leaderPID: nil),
        ]
        let result = ZmxInventory.join(observed: observed, claims: [], inventoryComplete: true)
        #expect(ZmxPrunePolicy.namesToPrune(result) == [])
    }

    @Test func pruneNeverReturnsAClaimedPaneWhoseDaemonIsAbsent() {
        let result = ZmxInventory.join(observed: [], claims: [Self.claim(Self.paneA)], inventoryComplete: true)
        #expect(ZmxPrunePolicy.namesToPrune(result) == [])
    }
}
