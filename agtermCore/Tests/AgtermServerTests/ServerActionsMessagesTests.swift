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

    private final class FrameSink: PresentationSink {
        var messages: [PresentationMessage] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            if case .message(let message) = frame.body { messages.append(message) }
            return true
        }
        func close(_: PresentationHub.CloseReason) {}
    }

    private func subscribe(_ session: Session, mode: PresentationMode = .mirror) throws -> FrameSink {
        let sink = FrameSink()
        let hub = try #require(harness.store.presentationHub)
        _ = try hub.subscribe(session: session.id, hello: PresentationHello(version: PresentationCodec.version,
                                                                            kinds: PresentationHub.supportedKinds, mode: mode),
                              sink: sink) { harness.store.presentationSnapshot(forSession: session.id) }
        return sink
    }

    private func splitWithScratch() async throws -> (session: Session, right: UUID, scratch: UUID) {
        let session = try await newSession()
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        _ = harness.actions.scratchSession(session.id.uuidString, window: nil, mode: "on", command: nil)
        _ = harness.actions.scratchSession(session.id.uuidString, window: nil, mode: "off", command: nil)
        return (session, try #require(session.splitPaneIdentity), try #require(session.scratchDaemon?.identity))
    }

    private func deliver(_ count: Int, to pane: UUID) throws {
        for _ in 0..<count { _ = try MessageBus.shared.send("m", from: nil, to: [MessageRecipient(pane: pane, address: "S:\(pane)")], now: 1) }
    }

    @Test func anEndedRowDropsItsMainAndSplitMailAndKeepsItsRunningScratchs() async throws {
        let (session, right, scratch) = try await splitWithScratch()
        let main = session.paneIdentity
        try [main, right, scratch].forEach { try deliver(1, to: $0) }

        harness.store.markSessionEnded(session.id)

        #expect([main, right, scratch].map(MessageBus.shared.pending(for:)) == [0, 0, 1])
        MessageBus.shared.dispose(pane: scratch)
    }

    @Test(arguments: [false, true])
    func closingASessionOrItsWorkspaceDropsItsScratchMail(workspace: Bool) async throws {
        let created = await harness.actions.serve(ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "doomed")))
        let workspaceID = try #require(created.result?.id)
        let session = try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionNew,
                                                                                     args: ControlArgs(workspace: workspaceID))))
        _ = harness.actions.scratchSession(session.id.uuidString, window: nil, mode: "on", command: nil)
        let scratch = try #require(session.scratchDaemon?.identity)
        try deliver(1, to: scratch)

        let request = workspace ? ControlRequest(cmd: .workspaceDelete, target: workspaceID)
            : ControlRequest(cmd: .sessionClose, target: session.id.uuidString)
        #expect(await harness.actions.serve(request).ok)

        #expect(MessageBus.shared.pending(for: scratch) == 0)
    }

    @Test func closingASplitOrThePrimaryKeepsTheSurvivorsMail() async throws {
        let first = try await newSession()
        _ = harness.actions.splitSession(first.id.uuidString, window: nil, mode: "on")
        let (main, split) = (first.paneIdentity, try #require(first.splitPaneIdentity))
        try deliver(1, to: main)
        try deliver(1, to: split)

        _ = await harness.actions.serve(ControlRequest(cmd: .sessionSplitClose, target: first.id.uuidString))

        #expect([main, split].map(MessageBus.shared.pending(for:)) == [1, 0])
        MessageBus.shared.dispose(pane: main)

        let second = try await newSession()
        _ = harness.actions.splitSession(second.id.uuidString, window: nil, mode: "on")
        let (primary, survivor) = (second.paneIdentity, try #require(second.splitPaneIdentity))
        try deliver(1, to: primary)
        try deliver(1, to: survivor)

        #expect(harness.store.closePrimaryPane(second.id) == .promoted)

        #expect(second.paneIdentity == survivor)
        #expect([primary, survivor].map(MessageBus.shared.pending(for:)) == [0, 1])
        MessageBus.shared.dispose(pane: survivor)
    }

    @Test func aViewerLeavingKeepsTheMail() async throws {
        let session = try await newSession()
        let hub = try #require(harness.store.presentationHub)
        let id = try hub.subscribe(session: session.id, hello: PresentationHello(version: PresentationCodec.version, kinds: [], mode: .presenter),
                                   sink: FrameSink()) { harness.store.presentationSnapshot(forSession: session.id) }
        try deliver(1, to: session.paneIdentity)

        hub.unsubscribe(id)

        #expect(MessageBus.shared.pending(for: session.paneIdentity) == 1)
        MessageBus.shared.dispose(pane: session.paneIdentity)
    }

    @Test func theTreeReportsPaneMailOnItsSurfacesAndTheScratchsOnTheSession() async throws {
        let (session, right, scratch) = try await splitWithScratch()
        try deliver(2, to: session.paneIdentity)
        try deliver(1, to: right)
        try deliver(3, to: scratch)
        let node = { () throws -> ControlSessionNode in
            let tree = try #require(self.harness.actions.controlTree(window: nil).result?.tree)
            return try #require(tree.workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
        }

        let loaded = try node()
        [session.paneIdentity, right, scratch].forEach { MessageBus.shared.dispose(pane: $0) }
        let empty = try node()

        #expect(loaded.surfaces?.first { $0.kind == "left" }?.pendingMessages == 2)
        #expect(loaded.surfaces?.first { $0.kind == "right" }?.pendingMessages == 1)
        #expect(loaded.scratchPaneID == scratch.uuidString)
        #expect(loaded.scratchPendingMessages == 3)
        #expect(empty.surfaces?.allSatisfy { $0.pendingMessages == nil } == true)
        #expect(empty.scratchPaneID == scratch.uuidString)
        #expect(empty.scratchPendingMessages == nil)
    }

    @Test func theCatalogCarriesEachPanesCountAndOmitsZero() async throws {
        let (session, right, scratch) = try await splitWithScratch()
        try deliver(2, to: right)
        try deliver(1, to: scratch)

        let entry = try #require(harness.actions.catalogWorkspaces().flatMap(\.sessions).first { $0.id == session.id })
        [right, scratch].forEach { MessageBus.shared.dispose(pane: $0) }

        #expect(entry.panes.map(\.pendingMessages) == [nil, 2])
        #expect(entry.fields.scratch?.pane.pendingMessages == 1)
    }

    @Test func eachDeliveredPaneIsPublishedOnceToEverySubscriberOfItsSession() async throws {
        let (target, right, scratch) = try await splitWithScratch()
        let sender = try await newSession()
        let (presenter, mirror, own) = (try subscribe(target, mode: .presenter), try subscribe(target), try subscribe(sender))
        let from = address(sender, sender.paneIdentity)
        let prefix = target.id.uuidString

        let sent = await send("secret", to: ["\(prefix):left", "\(prefix):right", "\(prefix):scratch"], as: from)

        let id = try #require(sent.result?.messageID.flatMap(UUID.init(uuidString:)))
        let expected = [target.paneIdentity, right, scratch].map { PresentationMessage(pane: $0, from: from, messageID: id) }
        #expect(presenter.messages == expected)
        #expect(mirror.messages == expected)
        #expect(own.messages.isEmpty)
        [target.paneIdentity, right, scratch].forEach { MessageBus.shared.dispose(pane: $0) }
    }

    @Test func anEndedRowsScratchIsPublishedAndAFullMailboxIsNot() async throws {
        let ended = try await newSession()
        _ = harness.actions.scratchSession(ended.id.uuidString, window: nil, mode: "on", command: nil)
        let scratch = try #require(ended.scratchDaemon?.identity)
        harness.store.markSessionEnded(ended.id)
        let full = try await newSession()
        try deliver(MessageBus.maxMessages, to: full.paneIdentity)
        let (endedSink, fullSink) = (try subscribe(ended), try subscribe(full))

        _ = await send("x", to: ["\(ended.id.uuidString):scratch", "\(full.id.uuidString):left"])

        #expect(endedSink.messages.map(\.pane) == [scratch])
        #expect(fullSink.messages.isEmpty)
        [scratch, full.paneIdentity].forEach { MessageBus.shared.dispose(pane: $0) }
    }
}
