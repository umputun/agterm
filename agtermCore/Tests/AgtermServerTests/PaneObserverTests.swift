import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct PaneObserverTests {
    private let harness: ServerHarness
    private let observer: PaneObserver
    private let directories = DirectoryBox()

    init() throws {
        harness = try ServerHarness()
        let directories = directories
        observer = PaneObserver(store: harness.store, panes: harness.panes, cwd: { directories.value[$0] })
    }

    final class DirectoryBox: @unchecked Sendable {
        var value: [Int32: String] = [:]
    }

    private func session(split: Bool = false) throws -> Session {
        let reply = harness.actions.createSession(ControlSessionCreateOptions(window: nil, cwd: "/tmp", workspace: nil,
                                                                              workspaceName: nil, createWorkspace: nil,
                                                                              command: nil, wait: nil, name: nil, after: nil,
                                                                              before: nil, noSelect: false))
        let session = try harness.session(reply)
        if split { _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on") }
        return session
    }

    private func record(_ identity: UUID, pid: Int32 = 100) -> ZmxSessionRecord {
        ZmxSessionRecord(name: ZmxSupport.daemonName(for: identity), clients: 0, leaderPID: pid)
    }

    private func exited(_ identity: UUID) {
        FileManager.default.createFile(atPath: harness.panes.exitRecord(identity), contents: Data("exited\n".utf8))
    }

    private var later: Date { Date().addingTimeInterval(1) }

    @Test func aPageRowOutlivesListingsThatNameNoDaemonOfIt() async throws {
        let anchor = try session()
        var args = ControlArgs()
        args.url = "https://example.com/"
        let reply = await harness.actions.serve(ControlRequest(cmd: .sessionPage, target: anchor.id.uuidString, args: args))
        let row = try harness.session(reply)

        observer.apply([record(anchor.paneIdentity)], listedAt: later)
        observer.apply([], listedAt: later)

        #expect(harness.store.session(withID: row.id) === row)
        #expect(!row.ended)
        #expect(row.htmlOverlay != nil)
        #expect(row.daemonBackedPanes.isEmpty)
    }

    @Test func listedPanesAreAdoptedAfterARestart() throws {
        let session = try session(split: true)
        let split = try #require(session.splitPaneIdentity)
        session.daemonBackedPanes.removeAll()

        observer.apply([record(session.paneIdentity), record(split)], listedAt: later)

        #expect(session.daemonBackedPanes == [session.paneIdentity, split])
    }

    @Test func aRestartWithTheLeftPaneGoneAdoptsAndPromotesTheLiveSplit() throws {
        let session = try session(split: true)
        let split = try #require(session.splitPaneIdentity)
        session.daemonBackedPanes.removeAll()

        observer.apply([record(split)], listedAt: later)

        #expect(harness.store.session(withID: session.id) != nil)
        #expect(session.paneIdentity == split)
        #expect(!session.hasSplit)
        #expect(session.daemonBackedPanes == [split])
        #expect(!session.ended)
    }

    @Test func aPaneZmxCouldNotProbeStaysWhileAnAbsentOneSettles() throws {
        let busy = try session(), lost = try session()
        let listing = "name=\(ZmxSupport.daemonName(for: busy.paneIdentity))\terr=Timeout\tstatus=unreachable\n"

        observer.apply(try ZmxListParser.parse(listing), listedAt: later)

        #expect(!busy.ended)
        #expect(busy.daemonBackedPanes == [busy.paneIdentity])
        #expect(lost.ended)
    }

    @Test func aLostLastPaneLeavesTheSessionEnded() throws {
        let session = try session()

        observer.apply([], listedAt: later)

        #expect(harness.store.session(withID: session.id) != nil)
        #expect(session.ended)
        #expect(session.daemonBackedPanes.isEmpty)
        let node = harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
        #expect(node?.ended == true)
        #expect(harness.store.snapshot().workspaces.flatMap(\.sessions).first { $0.id == session.id }?.ended == true)
    }

    @Test func anExitedLastPaneClosesTheSessionAndUsesItsRecord() throws {
        let session = try session()
        exited(session.paneIdentity)

        observer.apply([], listedAt: later)

        #expect(harness.store.session(withID: session.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.panes.exitRecord(session.paneIdentity)))
    }

    @Test func aParentWithCompanionsRespawnsItsExitedShell() async throws {
        let parent = try session()
        let companion = try harness.session(await harness.actions.createCompanion(parent.id.uuidString,
                                                                                 options: CompanionOptions(), window: nil))
        exited(parent.paneIdentity)
        let launches = harness.runner.launches.count

        observer.apply([record(companion.paneIdentity)], listedAt: later)

        #expect(harness.store.session(withID: parent.id) != nil)
        #expect(harness.runner.launches.count == launches + 1)
        #expect(harness.runner.launches.last?.name == ZmxSupport.daemonName(for: parent.paneIdentity))
        #expect(parent.daemonBackedPanes == [parent.paneIdentity])
    }

    @Test func aLostSplitCollapsesToTheLivePrimary() throws {
        let session = try session(split: true)
        let primary = session.paneIdentity

        observer.apply([record(primary)], listedAt: later)

        #expect(session.paneIdentity == primary)
        #expect(!session.hasSplit)
        #expect(session.daemonBackedPanes == [primary])
    }

    @Test func aMixedExitAndLossEndsTheSession() throws {
        let session = try session(split: true)
        exited(session.paneIdentity)

        observer.apply([], listedAt: later)

        #expect(session.ended)
    }

    @Test func aPaneStartedAfterTheListingBeganIsLeftAlone() throws {
        let listedAt = Date()
        let session = try session()

        observer.apply([], listedAt: listedAt)

        #expect(!session.ended)
        #expect(session.daemonBackedPanes == [session.paneIdentity])
    }

    @Test func aFailedListingChangesNothing() async throws {
        let session = try session()
        harness.runner.records = nil

        await observer.tick()

        #expect(!session.ended)
        #expect(session.daemonBackedPanes == [session.paneIdentity])
    }

    @Test func anEndedSessionIsSkippedAndCannotGrowASplit() throws {
        let session = try session()
        observer.apply([], listedAt: later)

        observer.apply([record(session.paneIdentity)], listedAt: later)

        #expect(session.daemonBackedPanes.isEmpty)
        #expect(harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
            == ControlResponse(ok: false, error: "session has ended"))
        #expect(harness.actions.closeSession(session.id.uuidString, window: nil).ok)
        #expect(harness.store.session(withID: session.id) == nil)
    }

    @Test func eachPaneTakesTheDirectoryItsForegroundProcessIsIn() throws {
        let session = try session(split: true)
        let split = try #require(session.splitPaneIdentity)
        directories.value = [100: "/srv/app", 200: "/var/log"]

        observer.apply([record(session.paneIdentity, pid: 100), record(split, pid: 200)], listedAt: later)

        #expect(session.currentCwd == "/srv/app")
        #expect(session.splitCwd == "/var/log")
    }

    private func scratch(_ session: Session) throws -> UUID {
        _ = harness.actions.scratchSession(session.id.uuidString, window: nil, mode: "on", command: nil)
        return try #require(session.scratchDaemon?.identity)
    }

    private func scratchRecord(_ identity: UUID) -> ZmxSessionRecord {
        ZmxSessionRecord(name: ZmxSupport.scratchDaemonName(for: identity), clients: 0, leaderPID: 200)
    }

    @Test func aScratchWhoseDaemonIsGoneIsClearedAndItsPanesStay() throws {
        let session = try session()
        _ = try scratch(session)

        observer.apply([record(session.paneIdentity)], listedAt: later)

        #expect(session.scratchDaemon == nil)
        #expect(session.daemonBackedPanes == [session.paneIdentity])
        #expect(!session.ended)
    }

    @Test func aListedScratchStaysAndIsNeverAdoptedAsAPane() throws {
        let session = try session()
        let identity = try scratch(session)

        observer.apply([record(session.paneIdentity), scratchRecord(identity)], listedAt: later)

        #expect(session.scratchDaemon?.identity == identity)
        #expect(session.daemonBackedPanes == [session.paneIdentity])
    }

    @Test(arguments: [(StatusPane.scratch, AgentStatus.idle), (.right, .blocked)])
    func aGoneScratchClearsOnlyAStatusItOwned(owner: StatusPane, after: AgentStatus) throws {
        let session = try session(split: true)
        _ = try scratch(session)
        harness.store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: owner), forSession: session.id)
        let split = try #require(session.splitPaneIdentity)

        observer.apply([record(session.paneIdentity), record(split)], listedAt: later)

        #expect(session.scratchDaemon == nil)
        #expect(session.agentIndicator.status == after)
    }

    @Test func aScratchNoSessionOwnsIsEndedAtAnyListing() throws {
        let session = try session()
        let leftover = ZmxSupport.scratchDaemonName(for: UUID())
        let listing = [record(session.paneIdentity), ZmxSessionRecord(name: leftover, clients: 0, leaderPID: 300)]
        harness.runner.killFails = true

        observer.apply(listing, listedAt: later)
        harness.runner.killFails = false
        observer.apply(listing, listedAt: later)

        #expect(harness.runner.kills == [leftover, leftover])
        #expect(session.daemonBackedPanes == [session.paneIdentity])
    }

    @Test func theLastPaneLostLeavesTheSessionEndedWithItsScratchRunning() throws {
        let session = try session()
        let identity = try scratch(session)

        observer.apply([scratchRecord(identity)], listedAt: later)

        #expect(session.ended)
        #expect(session.scratchDaemon?.identity == identity)

        observer.apply([], listedAt: later)

        #expect(session.scratchDaemon == nil)
    }

    @Test(arguments: [
        ("1234 (zsh) S 1 1234 1234 34816 5678 4194560", Int32(5678)),
        ("1234 (my prog) R 1 1234 1234 34816 99 0", Int32(99)),
        ("1234 (sh) S 1 1234 1234 0 -1 0", nil),
    ] as [(String, Int32?)])
    func theForegroundGroupIsReadPastTheCommandName(stat: String, group: Int32?) {
        #expect(ProcCwd.parseForegroundGroup(stat) == group)
    }
}
