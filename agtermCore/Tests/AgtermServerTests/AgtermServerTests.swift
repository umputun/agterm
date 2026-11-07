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

        let second = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        defer { second.stop() }

        #expect(second.catalog.id == catalogID)
        #expect(second.store.workspaces.map(\.id).contains(workspace.id))
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

    @Test func aMarkerItsCommandSavedIsAnsweredAsAppliedAfterARestart() async throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let first = try AgtermServer.start(configuration: scratch.configuration(), identity: identity)
        var table = CatalogOperationTable()
        table.record(CatalogReceipt(opID: "crashed", epoch: first.actions.streams.catalogHub.epoch, outcome: .applied))
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
