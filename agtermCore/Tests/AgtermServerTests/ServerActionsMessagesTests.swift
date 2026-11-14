import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsMessagesTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() async throws -> Session {
        try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionNew)))
    }

    private func address(_ session: Session, _ pane: UUID) -> String { "\(session.id.uuidString):\(pane.uuidString)" }

    private func send(_ body: String, to recipients: [String], as identity: String? = nil) async -> ControlResponse {
        await harness.actions.serve(ControlRequest(cmd: .msgSend, args: ControlArgs(body: body, recipients: recipients, identity: identity)))
    }

    private func broadcast(_ body: String, workspace: String? = nil, as identity: String? = nil) async -> ControlResponse {
        await harness.actions.serve(ControlRequest(cmd: .msgSend, args: ControlArgs(workspace: workspace, body: body, all: true,
                                                                                    identity: identity)))
    }

    private func read(as identity: String, ack: Bool = false) async -> ControlResponse {
        await harness.actions.serve(ControlRequest(cmd: .msgRead, args: ControlArgs(identity: identity, ack: ack ? true : nil)))
    }

    private func ack(_ ids: [String], as identity: String) async -> ControlResponse {
        await harness.actions.serve(ControlRequest(cmd: .msgAck, args: ControlArgs(identity: identity, ids: ids)))
    }

    private func bodies(_ reply: ControlResponse) -> [String] { reply.result?.messages?.map(\.body) ?? [] }

    @Test func theTwoPanesOfASplitSendReadAndAck() async throws {
        let session = try await newSession()
        #expect(harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on").ok)
        let left = address(session, session.paneIdentity)
        let right = address(session, try #require(session.splitPaneIdentity))

        let sent = await send("build done", to: ["\(session.id.uuidString):right"], as: left)

        #expect(sent.ok)
        #expect(sent.result?.delivered == [right])
        let inbox = await read(as: right)
        #expect(bodies(inbox) == ["build done"])
        #expect(inbox.result?.messages?.first?.from == left)
        let id = try #require(inbox.result?.messages?.first?.id.uuidString)
        #expect(await ack([id], as: right).result?.acked == [id])
        #expect(bodies(await read(as: right)).isEmpty)
    }

    @Test func aPaneIDRecipientInAnotherSessionGetsTheMail() async throws {
        let first = try await newSession()
        let second = try await newSession()
        let target = address(second, second.paneIdentity)

        let sent = await send("hi", to: [target], as: address(first, first.paneIdentity))

        #expect(sent.result?.delivered == [target])
        #expect(bodies(await read(as: target, ack: true)) == ["hi"])
    }

    @Test func aHiddenSplitAndAHiddenScratchAreRecipientsAndIdentities() async throws {
        let session = try await newSession()
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "off")
        _ = harness.actions.scratchSession(session.id.uuidString, window: nil, mode: "on", command: nil)
        _ = harness.actions.scratchSession(session.id.uuidString, window: nil, mode: "off", command: nil)
        let right = address(session, try #require(session.splitPaneIdentity))
        let scratch = address(session, try #require(session.scratchDaemon?.identity))

        let sent = await send("x", to: ["\(session.id.uuidString):right", "\(session.id.uuidString):scratch"], as: scratch)

        #expect(sent.result?.delivered == [right, scratch])
        #expect(bodies(await read(as: right, ack: true)) == ["x"])
        #expect(bodies(await read(as: scratch, ack: true)) == ["x"])
    }

    @Test func aSwapKeepsTheMailWithThePaneIdentity() async throws {
        let session = try await newSession()
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)
        _ = await send("for the split", to: [address(session, split)])

        #expect(await harness.actions.swapSessionPanes(session.id.uuidString, window: nil).ok)

        #expect(session.paneIdentity == split)
        let left = await send("now left", to: ["\(session.id.uuidString):left"])
        #expect(left.result?.delivered == [address(session, split)])
        #expect(bodies(await read(as: address(session, split), ack: true)) == ["for the split", "now left"])
    }

    @Test func broadcastReachesEveryLivePaneButTheSenderAndWorkspaceNarrowsIt() async throws {
        let first = try await newSession()
        _ = harness.actions.splitSession(first.id.uuidString, window: nil, mode: "on")
        let other = try #require(harness.actions.createWorkspace(window: nil, name: "other", collapsed: false).result?.id)
        let second = try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionNew,
                                                                                    args: ControlArgs(workspace: other))))
        let sender = address(first, first.paneIdentity)
        let split = address(first, try #require(first.splitPaneIdentity))
        let elsewhere = address(second, second.paneIdentity)

        let all = await broadcast("all", as: sender)
        let narrowed = await broadcast("narrow", workspace: other)

        #expect(Set(all.result?.delivered ?? []) == [split, elsewhere])
        #expect(narrowed.result?.delivered == [elsewhere])
        _ = await read(as: split, ack: true)
        _ = await read(as: elsewhere, ack: true)
    }

    @Test func anUnknownPaneIsRejectedAloneAndTheRestIsDelivered() async throws {
        let session = try await newSession()
        let left = address(session, session.paneIdentity)
        let unknown = "\(session.id.uuidString):\(UUID().uuidString)"

        let sent = await send("x", to: [left, unknown, "\(session.id.uuidString):right"])

        #expect(sent.ok)
        #expect(sent.result?.delivered == [left])
        #expect(sent.result?.rejected == [MessageRejection(address: unknown, reason: .unknownPane),
                                          MessageRejection(address: "\(session.id.uuidString):right", reason: .unknownPane)])
        _ = await read(as: left, ack: true)
    }

    @Test(arguments: [Command.msgSend, .msgRead, .msgAck])
    func anIdentityThatIsNotALivePaneIsRefused(_ cmd: Command) async throws {
        let session = try await newSession()
        let stranger = address(session, UUID())

        let reply = await harness.actions.serve(ControlRequest(cmd: cmd, args: ControlArgs(body: "x", all: true, identity: stranger,
                                                                                           ids: [UUID().uuidString])))

        #expect(!reply.ok)
        #expect(reply.error?.contains("is not a live pane of session") == true)
    }

    @Test func anEndedRowTakesNoMailInItsMainPaneButItsRunningScratchDoes() async throws {
        let session = try await newSession()
        _ = harness.actions.scratchSession(session.id.uuidString, window: nil, mode: "on", command: nil)
        let scratch = address(session, try #require(session.scratchDaemon?.identity))
        harness.store.markSessionEnded(session.id)

        let sent = await send("x", to: ["\(session.id.uuidString):left", "\(session.id.uuidString):scratch"])

        #expect(sent.result?.delivered == [scratch])
        #expect(sent.result?.rejected == [MessageRejection(address: "\(session.id.uuidString):left", reason: .unknownPane)])
        _ = await read(as: scratch, ack: true)
    }

    @Test func aPageRowTakesNoMail() async throws {
        let anchor = try await newSession()
        var args = ControlArgs()
        args.url = "https://example.com/"
        let row = try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionPage, target: anchor.id.uuidString,
                                                                                 args: args)))

        let sent = await send("x", to: ["\(row.id.uuidString):left"])

        #expect(sent.result?.delivered == [])
        #expect(sent.result?.rejected == [MessageRejection(address: "\(row.id.uuidString):left", reason: .unknownPane)])
    }
}
