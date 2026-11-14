import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct AgtermServerTests {
    private let identity = AppIdentity(version: "1.2.3")

    @Test func theSocketAnswersVersionAsAHeadlessServer() async throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let server = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        defer { server.stop() }

        let reply = try await offPool { [path = server.configuration.socketPath] in
            try send(ControlRequest(cmd: .version), to: path)
        }

        #expect(reply.ok)
        #expect(reply.result?.headless == true)
    }

    @Test func anUnservedCommandIsRefusedBeforeDispatch() async throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let server = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        defer { server.stop() }

        let reply = try await offPool { [path = server.configuration.socketPath] in
            try send(ControlRequest(cmd: .windowNew), to: path)
        }

        #expect(reply == ControlResponse(ok: false, error: HeadlessCommandPolicy.physicalWindowRefusal(.windowNew)))
    }

    @Test func aSecondServerOnTheSameStateDirectoryIsRefused() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let first = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        defer { first.stop() }

        #expect(throws: AgtermServer.Failure.stateDirectoryHeld(scratch.state)) {
            try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        }
    }

    @Test func aRestartKeepsTheCatalogAndItsWorkspaces() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let first = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        let workspace = first.store.addWorkspace(name: "projects")
        let catalogID = first.catalog.id
        first.stop()

        let second: AgtermServer
        do {
            second = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        } catch {
            Issue.record("restart failed: \(error); test pid \(getpid()); lock holders: \(lockHolders(scratch.state + "/agterm.lock"))")
            return
        }
        defer { second.stop() }

        #expect(second.catalog.id == catalogID)
        #expect(second.store.workspaces.map(\.id).contains(workspace.id))
    }

    @Test func aStopInsideTheGraceEndsTheDaemonAndKeepsTheEntry() async throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let runner = listingRunner()
        let first = try AgtermServer.start(configuration: scratch.configuration(), identity: identity, runner: runner)
        let session = try newSession(first)
        let close = await first.handle(ControlRequest(cmd: .sessionClose, target: session.id.uuidString,
                                                      args: ControlArgs(undoable: true)))
        #expect(close.result?.undoable == true)

        first.stop()

        #expect(runner.kills == [ZmxSupport.daemonName(for: session.paneIdentity)])
        let second = try AgtermServer.start(configuration: scratch.configuration(), identity: identity, runner: runner)
        defer { second.stop() }
        #expect(second.store.session(withID: session.id) == nil)
        #expect(second.actions.listRecentClosed().result?.recent?.map(\.sessionIDs) == [[session.id.uuidString]])
    }

    @Test func aCrashInsideTheGraceIsFinishedAtStartAndItsEntryStillOpens() async throws {
        let scratch = try ServerScratch(), crashed = try ServerScratch()
        defer { scratch.remove(); crashed.remove() }
        let first = try AgtermServer.start(configuration: scratch.configuration(), identity: identity, runner: listingRunner())
        let parent = try newSession(first)
        let companionReply = await first.actions.createCompanion(parent.id.uuidString, options: CompanionOptions(), window: nil)
        let companion = try #require(companionReply.result?.id.flatMap(UUID.init(uuidString:)))
        let daemons = [parent.paneIdentity, try #require(first.store.session(withID: companion)).paneIdentity]
            .map(ZmxSupport.daemonName(for:))
        let close = await first.handle(ControlRequest(cmd: .sessionClose, target: parent.id.uuidString,
                                                      args: ControlArgs(undoable: true)))
        let recentID = try #require(close.result?.recentID)
        try FileManager.default.createDirectory(atPath: crashed.state, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(atPath: scratch.state) where file.hasSuffix(".json") {
            try FileManager.default.copyItem(atPath: scratch.state + "/" + file, toPath: crashed.state + "/" + file)
        }
        first.stop()
        let runner = listingRunner()
        runner.records = daemons.map { ZmxSessionRecord(name: $0, clients: 0, leaderPID: 100) }

        let second = try AgtermServer.start(configuration: crashed.configuration(), identity: identity, runner: runner)
        defer { second.stop() }

        #expect(second.store.session(withID: parent.id) == nil)
        #expect(second.store.session(withID: companion) == nil)
        #expect(Set(runner.kills) == Set(daemons))
        #expect(second.actions.listRecentClosed().result?.recent?.map(\.id) == [recentID])
        let reopen = second.actions.openRecentClosed(recentID, window: nil)
        #expect(reopen.ok, "\(reopen.error ?? "")")
        #expect(second.store.session(withID: companion)?.parentID == parent.id)
    }

    @Test func aShellExitPublishesTheNewRecentListWithNoCommandBetween() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let server = try AgtermServer.start(configuration: scratch.configuration(), identity: identity, runner: listingRunner())
        defer { server.stop() }
        let session = try newSession(server)
        #expect(server.actions.streams.catalogHub.snapshot().recent == [])

        server.observer.settleExited(session, identity: session.paneIdentity)

        #expect(server.store.session(withID: session.id) == nil)
        #expect(server.actions.streams.catalogHub.snapshot().recent?.map(\.sessionIDs) == [[session.id.uuidString]])
    }

    @Test func anUnreadableJournalOrARecoveryThatCannotSaveRefusesToStart() async throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let first = try AgtermServer.start(configuration: scratch.configuration(), identity: identity, runner: listingRunner())
        let session = try newSession(first)
        _ = await first.handle(ControlRequest(cmd: .sessionClose, target: session.id.uuidString, args: ControlArgs(undoable: true)))
        let journal = try Data(contentsOf: URL(fileURLWithPath: scratch.state + "/" + PendingCloseJournal.fileName))
        let catalog = try Data(contentsOf: URL(fileURLWithPath: scratch.state + "/workspaces.json"))
        first.stop()

        try Data("not json".utf8).write(to: URL(fileURLWithPath: scratch.state + "/" + PendingCloseJournal.fileName))
        #expect(performing: { try AgtermServer.start(configuration: scratch.configuration(), identity: identity, runner: listingRunner()) },
                throws: isUnrecovered)

        try journal.write(to: URL(fileURLWithPath: scratch.state + "/" + PendingCloseJournal.fileName))
        try catalog.write(to: URL(fileURLWithPath: scratch.state + "/workspaces.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.state)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.state) }
        #expect(performing: { try AgtermServer.start(configuration: scratch.configuration(), identity: identity, runner: listingRunner()) },
                throws: isUnrecovered)
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.state + "/" + PendingCloseJournal.fileName)) == journal)
    }

    private func isUnrecovered(_ error: any Error) -> Bool {
        guard case .unrecoveredPendingCloses = error as? AgtermServer.Failure else { return false }
        return true
    }

    private func listingRunner() -> FakeZmxRunner {
        let runner = FakeZmxRunner()
        runner.onCreate = { launch in
            runner.records = (runner.records ?? []) + [ZmxSessionRecord(name: launch.name, clients: 0, leaderPID: 100)]
        }
        return runner
    }

    private func newSession(_ server: AgtermServer) throws -> Session {
        let reply = server.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false))
        let id = try #require(reply.result?.id.flatMap(UUID.init(uuidString:)))
        return try #require(server.store.session(withID: id))
    }

    private func lockHolders(_ path: String) -> String {
        guard let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return "no lsof"
        }
        do {
            let output = try ServerProcess.run([lsof, "-w", "-n", path], environment: ProcessInfo.processInfo.environment, timeout: 10)
            return "exit \(output.status): \(output.stdout)\(output.stderr)"
        } catch {
            return "lsof failed: \(error)"
        }
    }

    @Test func anUnreadableSavedCatalogStopsTheStartAndIsLeftAlone() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(atPath: scratch.state, withIntermediateDirectories: true)
        let saved = scratch.state + "/workspaces.json"
        try Data("not json".utf8).write(to: URL(fileURLWithPath: saved))

        #expect(throws: AgtermServer.Failure.self) {
            try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        }
        #expect(try String(contentsOfFile: saved, encoding: .utf8) == "not json")
    }

    @Test func anAppliedOperationIsAnsweredAfterARestartAtARevisionTheNewEpochReaches() async throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let first = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        let firstEpoch = first.actions.streams.catalogHub.epoch
        var args = ControlArgs(name: "dev")
        args.opID = "ws"
        args.epoch = firstEpoch
        let applied = await first.handle(ControlRequest(cmd: .workspaceNew, args: args))
        first.stop()

        let second = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        defer { second.stop() }
        let hub = second.actions.streams.catalogHub
        let lookup = await second.handle(ControlRequest(cmd: .catalogOp, target: "ws"))
        args.epoch = hub.epoch
        let resent = await second.handle(ControlRequest(cmd: .workspaceNew, args: args))

        #expect(applied.result?.receipt?.outcome == .applied)
        #expect(hub.epoch != firstEpoch)
        #expect(lookup.result?.receipt == CatalogReceipt(opID: "ws", epoch: hub.epoch, outcome: .applied, rev: hub.snapshot().rev))
        #expect(resent.result?.receipt == lookup.result?.receipt)
        #expect(second.store.workspaces.filter { $0.name == "dev" }.count == 1)
    }

    @Test func anUnknownOutcomeIsStillUnknownAfterARestart() async throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let first = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        let sent = CatalogPosition(epoch: first.actions.streams.catalogHub.epoch, rev: 0)
        var table = CatalogOperationTable()
        for index in 0...CatalogOperationTable.capacity {
            table.record(CatalogReceipt(opID: "filler\(index)", epoch: sent.epoch, outcome: .noop), at: sent)
        }
        first.store.catalogOperations = table
        var args = ControlArgs()
        args.epoch = sent.epoch
        args.rev = sent.rev
        let before = await first.handle(ControlRequest(cmd: .catalogOp, target: "lost", args: args))
        first.stop()

        let second = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        defer { second.stop() }
        let after = await second.handle(ControlRequest(cmd: .catalogOp, target: "lost", args: args))

        #expect(before.result?.receipt?.outcome == .unknown)
        #expect(after.result?.receipt?.outcome == .unknown)
    }

    @Test func aMarkerItsCommandSavedIsAnsweredAsAppliedAfterARestart() async throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let first = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        var table = CatalogOperationTable()
        let epoch = first.actions.streams.catalogHub.epoch
        table.record(CatalogReceipt(opID: "crashed", epoch: epoch, outcome: .applied), at: CatalogPosition(epoch: epoch, rev: 0))
        first.store.catalogOperations = table
        first.stop()

        let second = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        defer { second.stop() }
        let hub = second.actions.streams.catalogHub
        let lookup = await second.handle(ControlRequest(cmd: .catalogOp, target: "crashed"))

        #expect(lookup.result?.receipt == CatalogReceipt(opID: "crashed", epoch: hub.epoch, outcome: .applied, rev: 0))
        #expect(hub.snapshot().rev == 0)
    }
}
