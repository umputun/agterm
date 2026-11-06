import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherMessagesTests {
    private let paneA = UUID()
    private let paneB = UUID()
    private var addressA: String { "S1:\(paneA.uuidString)" }
    private var addressB: String { "S2:\(paneB.uuidString)" }
    private var recipientA: MessageRecipient { MessageRecipient(pane: paneA, address: addressA) }
    private var recipientB: MessageRecipient { MessageRecipient(pane: paneB, address: addressB) }

    private func actions() -> MockControlActions {
        let actions = MockControlActions()
        actions.messagePanes = [
            MessageAddress(session: "s1", pane: .role(.left)): recipientA,
            MessageAddress(session: "S1", pane: .id(paneA)): recipientA,
            MessageAddress(session: "S2", pane: .id(paneB)): recipientB,
        ]
        actions.broadcastPanes = [recipientA, recipientB]
        return actions
    }

    private func dispatch(_ cmd: Command, _ args: ControlArgs, actions: MockControlActions, bus: MessageBus) async -> ControlResponse? {
        await ControlDispatcher(actions: actions, bus: bus).dispatch(ControlRequest(cmd: cmd, args: args))
    }

    @Test func sendDeliversOncePerResolvedPaneAndRejectsTheUnresolved() async throws {
        let (actions, bus) = (actions(), MessageBus())

        let response = await dispatch(.msgSend, ControlArgs(body: "hi", recipients: ["s1:left", addressA, "s9:right"]),
                                      actions: actions, bus: bus)

        let result = try #require(response?.result)
        #expect(response?.ok == true)
        #expect(result.delivered == [addressA])
        #expect(result.rejected == [MessageRejection(address: "s9:right", reason: .unknownPane)])
        let id = try #require(result.messageID)
        #expect(bus.read(pane: paneA).messages.map(\.id.uuidString) == [id])
        #expect(bus.read(pane: paneA).messages.first?.from == nil)
        #expect(actions.queuedMessages == [MockControlActions.Queued(id: id, from: nil, recipients: [recipientA])])
    }

    @Test func broadcastExcludesTheSenderAndStampsItsIdentity() async throws {
        let (actions, bus) = (actions(), MessageBus())

        let response = await dispatch(.msgSend, ControlArgs(body: "hi", all: true, identity: addressA),
                                      actions: actions, bus: bus)

        #expect(response?.result?.delivered == [addressB])
        #expect(bus.pending(for: paneA) == 0)
        #expect(bus.read(pane: paneB).messages.first?.from == addressA)
    }

    @Test func anonymousBroadcastReachesEveryPaneAndPassesItsScope() async {
        let (actions, bus) = (actions(), MessageBus())

        let response = await dispatch(.msgSend, ControlArgs(workspace: "w1", window: "win", body: "hi", all: true),
                                      actions: actions, bus: bus)

        #expect(response?.result?.delivered == [addressA, addressB])
        #expect(actions.broadcastScopes == [MockControlActions.Scope(workspace: "w1", window: "win")])
    }

    @Test func aSendThatDeliversNothingQueuesNoEvent() async {
        let (actions, bus) = (actions(), MessageBus())

        let response = await dispatch(.msgSend, ControlArgs(body: "hi", recipients: ["s9:right"]), actions: actions, bus: bus)

        #expect(response?.ok == true)
        #expect(response?.result?.delivered == [])
        #expect(actions.queuedMessages.isEmpty)
    }

    // a host without the bus answered an anonymous --to send ok with every recipient rejected
    @Test func aHostWithoutTheBusRefusesAnAnonymousSend() async {
        let (actions, bus) = (actions(), MessageBus())
        actions.messagesUnsupported = true

        let response = await dispatch(.msgSend, ControlArgs(body: "hi", recipients: ["s1:left"]), actions: actions, bus: bus)

        #expect(response == ControlResponse(ok: false, error: "msg is not supported on this platform"))
        #expect(bus.pending(for: paneA) == 0)
    }

    @Test func everyRecipientUnknownOnASupportingHostIsStillOk() async {
        let response = await dispatch(.msgSend, ControlArgs(body: "hi", recipients: ["s8:left", "s9:right"]),
                                      actions: actions(), bus: MessageBus())

        #expect(response?.ok == true)
        #expect(response?.result?.rejected?.map(\.reason) == [.unknownPane, .unknownPane])
    }

    @Test(arguments: [
        (ControlArgs(recipients: ["S1:left"]), "msg.send requires a body"),
        (ControlArgs(body: "hi"), "msg.send requires --to or --all"),
        (ControlArgs(body: "hi", recipients: []), "msg.send requires --to or --all"),
        (ControlArgs(body: "hi", all: true, recipients: ["S1:left"]), "msg.send takes --to or --all, not both"),
        (ControlArgs(workspace: "w1", body: "hi", recipients: ["S1:left"]), "msg.send: --workspace narrows --all only"),
        (ControlArgs(body: "hi", recipients: ["S1"]), MessageAddressError.bareSession("S1").message),
        (ControlArgs(body: "hi", recipients: ["S1:nope"]), MessageAddressError.malformed("S1:nope").message),
        (ControlArgs(body: "hi", all: true, identity: "S1:left"), MessageAddressError.roleIdentity("S1:left").message),
    ])
    func sendRefusesBeforeQueueing(args: ControlArgs, error: String) async {
        let (actions, bus) = (actions(), MessageBus())

        let response = await dispatch(.msgSend, args, actions: actions, bus: bus)

        #expect(response?.ok == false)
        #expect(response?.error == error)
        #expect(bus.pending(for: paneA) == 0)
    }

    @Test func anOversizedBodyIsRefused() async {
        let body = String(repeating: "x", count: MessageBus.maxBodyBytes + 1)

        let response = await dispatch(.msgSend, ControlArgs(body: body, recipients: [addressA]), actions: actions(), bus: MessageBus())

        #expect(response?.error == "message body too large (\(MessageBus.maxBodyBytes + 1) bytes, max \(MessageBus.maxBodyBytes))")
    }

    @Test(arguments: [Command.msgSend, .msgRead, .msgAck])
    func anIdentityTheHostRefusesFailsTheCommand(cmd: Command) async {
        let (actions, bus) = (actions(), MessageBus())
        let stranger = "S1:\(UUID().uuidString)"

        let response = await dispatch(cmd, ControlArgs(body: "hi", all: true, identity: stranger, ids: [UUID().uuidString]),
                                      actions: actions, bus: bus)

        #expect(response?.ok == false)
        #expect(response?.error == "pane not found: \(stranger)")
        #expect(bus.pending(for: paneB) == 0)
    }

    @Test(arguments: [Command.msgRead, .msgAck])
    func readAndAckRequireAnIdentity(cmd: Command) async {
        let response = await dispatch(cmd, ControlArgs(ids: [UUID().uuidString]), actions: actions(), bus: MessageBus())

        #expect(response?.error == "\(cmd.rawValue) requires an identity: --as SESSION:PANE-ID")
    }

    @Test func readLeavesTheMessagesAndCarriesNoAckField() async throws {
        let bus = MessageBus()
        _ = try bus.send("one", from: nil, to: [recipientA], now: 1)

        let response = await dispatch(.msgRead, ControlArgs(identity: addressA), actions: actions(), bus: bus)

        #expect(response?.result?.messages?.map(\.body) == ["one"])
        #expect(response?.result?.remaining == 0)
        #expect(response?.result?.acked == nil)
        #expect(bus.pending(for: paneA) == 1)
    }

    @Test func readWithAckRemovesTheBatchAndNamesIt() async throws {
        let bus = MessageBus()
        let sent = try bus.send("one", from: nil, to: [recipientA], now: 1)

        let response = await dispatch(.msgRead, ControlArgs(identity: addressA, ack: true), actions: actions(), bus: bus)
        let empty = await dispatch(.msgRead, ControlArgs(identity: addressA, ack: true), actions: actions(), bus: bus)

        #expect(response?.result?.acked == [sent.messageID.uuidString])
        #expect(bus.pending(for: paneA) == 0)
        #expect(empty?.result?.acked == [])
        #expect(empty?.result?.messages == [])
    }

    @Test func ackRemovesTheNamedMessagesOnly() async throws {
        let bus = MessageBus()
        let first = try bus.send("one", from: nil, to: [recipientA], now: 1)
        _ = try bus.send("two", from: nil, to: [recipientA], now: 2)

        let response = await dispatch(.msgAck, ControlArgs(identity: addressA, ids: [first.messageID.uuidString.lowercased()]),
                                      actions: actions(), bus: bus)

        #expect(response?.result?.acked == [first.messageID.uuidString])
        #expect(bus.read(pane: paneA).messages.map(\.body) == ["two"])
    }

    @Test(arguments: [(nil as [String]?, "msg.ack requires message ids"), ([], "msg.ack requires message ids"),
                      (["nope"], "invalid message id: nope")])
    func ackRefusesMissingOrMalformedIDs(ids: [String]?, error: String) async {
        let response = await dispatch(.msgAck, ControlArgs(identity: addressA, ids: ids), actions: actions(), bus: MessageBus())

        #expect(response?.error == error)
    }

    @Test func theNewFieldsRoundTripAndTheScalarToKeepsItsMeaning() throws {
        let request = ControlRequest(cmd: .msgSend, args: ControlArgs(to: "next", body: "b", all: true,
                                                                      recipients: ["S:left"], identity: "S:P", ack: true,
                                                                      ids: ["i"]))
        let result = ControlResult(messageID: "m", delivered: ["S:P"], rejected: [MessageRejection(address: "x", reason: .mailboxFull)],
                                   messages: [BusMessage(id: paneA, from: nil, to: "S:P", ts: 1, body: "b")], remaining: 2,
                                   acked: ["m"])

        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(try JSONDecoder().decode(ControlResult.self, from: JSONEncoder().encode(result)) == result)
        let go = ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "next"))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(go)).args?.to == "next")
    }

    @Test func pendingMessagesIsOmittedWhenThereAreNone() throws {
        let none = ControlSurfaceNode(id: "s", kind: "left", active: true, visible: true, backedByZmx: nil)
        let some = ControlSurfaceNode(id: "s", kind: "left", active: true, visible: true, backedByZmx: nil, pendingMessages: 3)

        #expect(String(decoding: try JSONEncoder().encode(none), as: UTF8.self).contains("pendingMessages") == false)
        #expect(try JSONDecoder().decode(ControlSurfaceNode.self, from: JSONEncoder().encode(some)).pendingMessages == 3)
    }

    @Test func theMessageEventCarriesSenderAndIDButNoBody() throws {
        let payload = ControlEventPayload(paneID: "P", from: "S:Q", messageID: "m")
        let event = ControlEvent(seq: 1, ts: 1, kind: .message, session: "S", payload: payload)

        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)

        #expect(json.contains("\"kind\":\"message\""))
        #expect(try JSONDecoder().decode(ControlEvent.self, from: JSONEncoder().encode(event)) == event)
        #expect(payload.body == nil)
    }
}
