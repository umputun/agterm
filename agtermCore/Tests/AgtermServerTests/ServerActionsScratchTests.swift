import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsScratchTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() async throws -> Session {
        try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionNew)))
    }

    private func scratch(_ session: Session, _ mode: String, command: String? = nil) -> ControlResponse {
        harness.actions.scratchSession(session.id.uuidString, window: nil, mode: mode, command: command)
    }

    private var scratchLaunches: [PaneLaunch] { harness.runner.launches.filter { ZmxSupport.isScratchDaemonName($0.name) } }

    @Test func onOffOnShowsTheSameDaemon() async throws {
        let session = try await newSession()

        #expect(scratch(session, "on").ok)
        let identity = try #require(session.scratchDaemon?.identity)
        #expect(scratch(session, "off").ok)
        #expect(session.scratchDaemon == Session.ScratchDaemon(identity: identity, shown: false))
        #expect(scratch(session, "toggle").ok)

        #expect(session.scratchDaemon == Session.ScratchDaemon(identity: identity, shown: true))
        #expect(scratchLaunches.map(\.name) == [ZmxSupport.scratchDaemonName(for: identity)])
        #expect(harness.runner.kills.isEmpty)
        #expect(!session.daemonBackedPanes.contains(identity))
    }

    @Test func theScratchStartsInTheSessionCwdAsTheScratchPane() async throws {
        let session = try await newSession()

        _ = scratch(session, "on")

        let launch = try #require(scratchLaunches.first)
        let identity = try #require(session.scratchDaemon?.identity)
        #expect(launch.directory == session.effectiveCwd)
        #expect(launch.environment["AGTERM_PANE"] == "scratch")
        #expect(launch.environment["AGTERM_PANE_ID"] == identity.uuidString)
        #expect(session.paneRole(forToken: identity.uuidString) == .scratch)
        #expect(session.paneToken(for: .scratch) == identity.uuidString)
    }

    @Test(arguments: [true, false])
    func onWithACommandReplacesTheScratch(shown: Bool) async throws {
        let session = try await newSession()
        _ = scratch(session, "on")
        let old = try #require(session.scratchDaemon?.identity)
        if !shown { _ = scratch(session, "off") }

        #expect(scratch(session, "on", command: "htop").ok)

        let new = try #require(session.scratchDaemon)
        #expect(new.identity != old)
        #expect(new.shown)
        #expect(harness.runner.kills == [ZmxSupport.scratchDaemonName(for: old)])
        #expect(scratchLaunches.map(\.name) == [ZmxSupport.scratchDaemonName(for: old), ZmxSupport.scratchDaemonName(for: new.identity)])
    }

    @Test func aStaleExpectedScratchIsRefusedAndLeavesTheReplacementRunning() async throws {
        let session = try await newSession()
        _ = scratch(session, "on")
        let stale = try #require(session.scratchDaemon?.identity)
        _ = scratch(session, "on", command: "htop")
        let current = try #require(session.scratchDaemon?.identity)
        var args = ControlArgs(mode: "on", command: "top")
        args.opID = "replace"
        args.epoch = harness.actions.streams.catalogHub.epoch
        args.scratch = stale.uuidString

        let reply = await harness.actions.serve(ControlRequest(cmd: .sessionScratch, target: session.id.uuidString, args: args))

        #expect(!reply.ok)
        #expect(reply.error == "the session's scratch changed; take the catalog again")
        #expect(session.scratchDaemon?.identity == current)
        #expect(!harness.runner.kills.contains(ZmxSupport.scratchDaemonName(for: current)))
    }

    @Test func anExpectedScratchThatMatchesIsServedWithAReceipt() async throws {
        let session = try await newSession()
        var args = ControlArgs(mode: "on")
        args.opID = "first"
        args.epoch = harness.actions.streams.catalogHub.epoch
        args.scratch = "none"

        let reply = await harness.actions.serve(ControlRequest(cmd: .sessionScratch, target: session.id.uuidString, args: args))

        #expect(reply.ok)
        #expect(reply.result?.receipt?.outcome == .applied)
        #expect(session.scratchDaemon?.shown == true)
    }

    @Test func closingTheSessionEndsItsScratch() async throws {
        let session = try await newSession()
        _ = scratch(session, "on")
        let identity = try #require(session.scratchDaemon?.identity)

        #expect(harness.actions.closeSession(session.id.uuidString, window: nil).ok)

        #expect(harness.runner.kills.contains(ZmxSupport.scratchDaemonName(for: identity)))
        #expect(harness.runner.kills.contains(ZmxSupport.daemonName(for: session.paneIdentity)))
    }

    @Test func textAndTypeReachTheScratchDaemon() async throws {
        let session = try await newSession()
        _ = scratch(session, "on")
        let name = ZmxSupport.scratchDaemonName(for: try #require(session.scratchDaemon?.identity))
        harness.runner.screens[name] = "scratch output"

        let text = harness.actions.readSessionText(session.id.uuidString, window: nil,
                                                   options: ControlSessionTextOptions(pane: .scratch, paneID: nil, all: false, lines: nil))

        #expect(text.ok)
        #expect(text.result?.text?.contains("scratch output") == true)
    }

    @Test func theScratchPaneIsNotRealizedWithoutAScratch() async throws {
        let session = try await newSession()

        let text = harness.actions.readSessionText(session.id.uuidString, window: nil,
                                                   options: ControlSessionTextOptions(pane: .scratch, paneID: nil, all: false, lines: nil))

        #expect(text.error == "session not realized")
    }

    @Test func anotherWindowIsRefusedBeforeTheScratchIsTouched() async throws {
        let session = try await newSession()
        _ = scratch(session, "on")
        let identity = try #require(session.scratchDaemon?.identity)

        let reply = harness.actions.scratchSession(session.id.uuidString, window: UUID().uuidString, mode: "on", command: "htop")

        #expect(reply.error?.hasPrefix("window not found") == true)
        #expect(session.scratchDaemon?.identity == identity)
        #expect(harness.runner.kills.isEmpty)
        #expect(scratchLaunches.count == 1)
    }

    @Test(arguments: [(StatusPane.scratch, AgentStatus.idle), (.left, .blocked)])
    func replacingTheScratchClearsOnlyAStatusItOwned(owner: StatusPane, after: AgentStatus) async throws {
        let session = try await newSession()
        _ = scratch(session, "on")
        harness.store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: owner), forSession: session.id)

        _ = scratch(session, "on", command: "htop")

        #expect(session.agentIndicator.status == after)
    }

    @Test func anInvalidModeIsRefused() async throws {
        let session = try await newSession()

        #expect(scratch(session, "sideways").error == "invalid scratch mode: sideways")
        #expect(session.scratchDaemon == nil)
    }

    @Test func aFailedStartLeavesNoScratch() async throws {
        let session = try await newSession()
        harness.runner.failure = "boom"

        #expect(!scratch(session, "on").ok)
        #expect(session.scratchDaemon == nil)
    }
}
