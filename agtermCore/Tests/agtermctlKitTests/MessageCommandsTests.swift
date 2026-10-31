import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct MessageCommandsTests {
    private let session = "AAAA1111-0000-4000-8000-000000000001"
    private let pane = "BBBB2222-0000-4000-8000-000000000002"
    private let first = UUID(uuidString: "CCCC3333-0000-4000-8000-000000000003")!
    private let second = UUID(uuidString: "DDDD4444-0000-4000-8000-000000000004")!

    private final class FakeApp {
        var replies: [ControlResponse]
        var requests: [ControlRequest] = []
        var sleeps: [TimeInterval] = []
        var clock: TimeInterval = 0

        init(_ replies: [ControlResponse]) { self.replies = replies }

        var dependencies: MessageReadDependencies {
            MessageReadDependencies(
                send: { request in
                    self.requests.append(request)
                    let response = self.replies.count > 1 ? self.replies.removeFirst() : self.replies[0]
                    return SocketReply(response: response, raw: try JSONEncoder().encode(response))
                },
                sleep: { delay in
                    self.sleeps.append(delay)
                    self.clock += delay
                },
                now: { self.clock })
        }
    }

    private func parse<T: ParsableCommand>(_ argv: [String], as type: T.Type) throws -> T {
        try #require(try Agtermctl.parseAsRoot(["msg"] + argv) as? T)
    }

    private func message(_ id: UUID, body: String, from: String? = nil) -> BusMessage {
        BusMessage(id: id, from: from, to: "\(session):\(pane)", ts: 1, body: body)
    }

    private func reply(_ result: ControlResult?, ok: Bool = true, error: String? = nil) throws -> SocketReply {
        let response = ControlResponse(ok: ok, result: result, error: error)
        return SocketReply(response: response, raw: try JSONEncoder().encode(response))
    }

    private var env: [String: String] { ["AGTERM_SESSION_ID": session, "AGTERM_PANE_ID": pane] }

    @Test func identityComesFromThePanesEnvironment() throws {
        let send = try parse(["send", "hi", "--to", "\(session):right"], as: Msg.Send.self)
        #expect(try send.makeRequest(body: "hi", env: env).args?.identity == "\(session):\(pane)")
    }

    @Test func asOverridesTheEnvironment() throws {
        let send = try parse(["send", "hi", "--all", "--as", "S:P"], as: Msg.Send.self)
        #expect(try send.makeRequest(body: "hi", env: env).args?.identity == "S:P")
        #expect(try send.makeRequest(body: "hi", env: ["AGTERM_SESSION_ID": session]).args?.identity == "S:P")
    }

    @Test(arguments: [["AGTERM_SESSION_ID": "S"], ["AGTERM_PANE_ID": "P"], ["AGTERM_SESSION_ID": "S", "AGTERM_PANE_ID": ""],
                      ["AGTERM_SESSION_ID": ""], ["AGTERM_PANE_ID": ""], ["AGTERM_SESSION_ID": "", "AGTERM_PANE_ID": ""]])
    func anIncompleteEnvironmentPairIsAnError(_ env: [String: String]) throws {
        let send = try parse(["send", "hi", "--all"], as: Msg.Send.self)
        #expect(throws: SocketClientError.self) { try send.makeRequest(body: "hi", env: env) }
    }

    @Test func withoutAnyIdentitySendIsAnonymousAndReadSendsNone() throws {
        let send = try parse(["send", "hi", "--all"], as: Msg.Send.self)
        let read = try parse(["read"], as: Msg.Read.self)
        let ack = try parse(["ack", first.uuidString], as: Msg.Ack.self)
        #expect(try send.makeRequest(body: "hi", env: [:]).args?.identity == nil)
        #expect(try read.makeRequest(env: [:]).args?.identity == nil)
        #expect(try ack.makeRequest(env: [:]).args?.identity == nil)
    }

    @Test func sendCarriesRecipientsWorkspaceAndBody() throws {
        let send = try parse(["send", "x", "--to", "a:left", "--to", "b:right"], as: Msg.Send.self)
        let request = try send.makeRequest(body: "x", env: [:])
        #expect(request.cmd == .msgSend)
        #expect(request.args?.recipients == ["a:left", "b:right"])
        #expect(request.args?.all == nil)
        #expect(request.args?.body == "x")

        let broadcast = try parse(["send", "--stdin", "--all", "--workspace", "w"], as: Msg.Send.self)
        let all = try broadcast.makeRequest(body: "y", env: [:])
        #expect(all.args?.all == true)
        #expect(all.args?.workspace == "w")
        #expect(all.args?.recipients == nil)
    }

    @Test(arguments: [["send", "--to", "a:left"], ["send", "hi", "--stdin", "--to", "a:left"]])
    func sendNeedsExactlyOneBodySource(_ argv: [String]) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["msg"] + argv) }
    }

    @Test func sendPrintsTheIdAndReportsRejectionsAsAFailure() throws {
        let clean = try reply(ControlResult(messageID: first.uuidString, delivered: ["a:b"], rejected: []))
        #expect(Msg.Send.output(clean, json: false) == MessageOutput(stdout: first.uuidString + "\n"))

        let partial = try reply(ControlResult(messageID: first.uuidString, delivered: ["a:b"], rejected: [
            MessageRejection(address: "c:d", reason: .mailboxFull), MessageRejection(address: "e:f", reason: .unknownPane)]))
        #expect(Msg.Send.output(partial, json: false) == MessageOutput(
            stdout: first.uuidString + "\n", stderr: "rejected c:d: mailbox full\nrejected e:f: unknown pane\n", failed: true))
        #expect(Msg.Send.output(partial, json: true) == MessageOutput(stdout: partial.line + "\n", failed: true))
    }

    @Test func aBroadcastReachingNoPaneSucceeds() throws {
        let empty = try reply(ControlResult(messageID: first.uuidString, delivered: [], rejected: []))
        #expect(Msg.Send.output(empty, json: false).failed == false)
    }

    @Test func aServerErrorFailsEveryCommand() throws {
        let refused = try reply(nil, ok: false, error: "msg.read requires an identity: --as SESSION:PANE-ID")
        let human = MessageOutput(stderr: "error: msg.read requires an identity: --as SESSION:PANE-ID\n", failed: true)
        #expect(Msg.Send.output(refused, json: false) == human)
        #expect(try parse(["read"], as: Msg.Read.self).output(refused) == human)
        #expect(Msg.Ack.output(refused, json: false) == human)
        #expect(Msg.Ack.output(refused, json: true) == MessageOutput(stdout: refused.line + "\n", failed: true))
    }

    @Test func readPrintsEachMessageAsItsOwnRecord() throws {
        let batch = try reply(ControlResult(messages: [message(first, body: "one", from: "S:P"), message(second, body: "two\n")],
                                            remaining: 3))
        let output = try parse(["read"], as: Msg.Read.self).output(batch)
        #expect(output == MessageOutput(
            stdout: "\(first.uuidString) from S:P\none\n\(second.uuidString) from outside agterm\ntwo\n",
            stderr: "3 more pending\n"))
    }

    @Test func anEmptyReadPrintsNothing() throws {
        let empty = try reply(ControlResult(messages: [], remaining: 0))
        #expect(try parse(["read"], as: Msg.Read.self).output(empty) == MessageOutput())
    }

    @Test func readJSONIsTheServerLine() throws {
        let batch = try reply(ControlResult(messages: [message(first, body: "one")], remaining: 0))
        #expect(try parse(["read", "--json"], as: Msg.Read.self).output(batch) == MessageOutput(stdout: batch.line + "\n"))
    }

    @Test func readAckSendsAckAndPrintsWhenTheAppConfirmsIt() throws {
        let read = try parse(["read", "--ack"], as: Msg.Read.self)
        #expect(try read.makeRequest(env: env).args?.ack == true)
        let confirmed = try reply(ControlResult(messages: [message(first, body: "one")], remaining: 0, acked: [first.uuidString]))
        #expect(read.output(confirmed) == MessageOutput(stdout: "\(first.uuidString) from outside agterm\none\n"))
    }

    @Test(arguments: [nil, [String](), ["00000000-0000-4000-8000-000000000000"]])
    func readAckFailsWithoutPrintingWhenTheAppDoesNotConfirm(_ acked: [String]?) throws {
        let batch = try reply(ControlResult(messages: [message(first, body: "one")], remaining: 0, acked: acked))
        for argv in [["read", "--ack"], ["read", "--ack", "--json"]] {
            let output = try parse(argv, as: Msg.Read.self).output(batch)
            #expect(output.stdout.isEmpty)
            #expect(output.failed)
            #expect(!output.stderr.isEmpty)
        }
    }

    @Test func readWithoutWaitAsksOnce() throws {
        let fake = FakeApp([ControlResponse(ok: true, result: ControlResult(messages: [], remaining: 0))])
        let read = try parse(["read"], as: Msg.Read.self)
        guard case .reply = try read.read(read.makeRequest(env: env), dependencies: fake.dependencies) else {
            Issue.record("expected a reply")
            return
        }
        #expect(fake.requests.count == 1)
    }

    @Test func waitPollsTheRealReadUntilMailArrives() throws {
        let empty = ControlResponse(ok: true, result: ControlResult(messages: [], remaining: 0, acked: []))
        let mail = ControlResponse(ok: true, result: ControlResult(messages: [message(first, body: "one")], remaining: 0,
                                                                   acked: [first.uuidString]))
        let fake = FakeApp([empty, empty, mail])
        let read = try parse(["read", "--wait", "--ack"], as: Msg.Read.self)

        let outcome = try read.read(read.makeRequest(env: env), dependencies: fake.dependencies)

        guard case .reply(let reply) = outcome else {
            Issue.record("expected a reply")
            return
        }
        #expect(reply.response.result?.messages?.map(\.id) == [first])
        #expect(fake.requests.count == 3)
        #expect(fake.requests.allSatisfy { $0.cmd == .msgRead && $0.args?.ack == true })
        #expect(fake.sleeps == [Msg.Read.pollDelay, Msg.Read.pollDelay])
    }

    @Test func waitStopsOnAServerErrorOrAnUnconfirmedAck() throws {
        let refused = FakeApp([ControlResponse(ok: false, error: "pane gone")])
        let read = try parse(["read", "--wait", "--ack"], as: Msg.Read.self)
        _ = try read.read(read.makeRequest(env: env), dependencies: refused.dependencies)
        #expect(refused.requests.count == 1)

        let ignored = FakeApp([ControlResponse(ok: true, result: ControlResult(messages: [], remaining: 0))])
        _ = try read.read(read.makeRequest(env: env), dependencies: ignored.dependencies)
        #expect(ignored.requests.count == 1)
    }

    @Test func waitTimesOut() throws {
        let fake = FakeApp([ControlResponse(ok: true, result: ControlResult(messages: [], remaining: 0))])
        let read = try parse(["read", "--wait", "--timeout", "1"], as: Msg.Read.self)
        guard case .timedOut = try read.read(read.makeRequest(env: env), dependencies: fake.dependencies) else {
            Issue.record("expected a timeout")
            return
        }
        #expect(fake.clock == 1)
        #expect(Msg.Read.timeoutExitCode == 124)
    }

    @Test(arguments: [["read", "--timeout", "5"], ["read", "--wait", "--timeout", "0"], ["read", "--wait", "--timeout", "-1"]])
    func timeoutNeedsWaitAndAPositiveValue(_ argv: [String]) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["msg"] + argv) }
    }

    @Test func ackSendsTheIdsAndCountsWhatWasRemoved() throws {
        let ack = try parse(["ack", first.uuidString, second.uuidString], as: Msg.Ack.self)
        let request = try ack.makeRequest(env: env)
        #expect(request.cmd == .msgAck)
        #expect(request.args?.ids == [first.uuidString, second.uuidString])
        #expect(request.args?.identity == "\(session):\(pane)")

        let removed = try reply(ControlResult(acked: [first.uuidString]))
        #expect(Msg.Ack.output(removed, json: false) == MessageOutput(stdout: "acked 1\n"))
        #expect(Msg.Ack.output(removed, json: true) == MessageOutput(stdout: removed.line + "\n"))
    }

    @Test func ackNeedsAnId() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["msg", "ack"]) }
    }
}
