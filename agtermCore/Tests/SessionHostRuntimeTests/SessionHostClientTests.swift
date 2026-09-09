import Foundation
import Testing
import agtermCore
@testable import SessionHostRuntime

struct SessionHostClientTests {
    @Test(arguments: [SessionHost.Ready.State.existing, .created])
    func successAttachesWithoutPayload(_ state: SessionHost.Ready.State) throws {
        let peer = Peer(reply: .ok(.init(state: state, leaderPid: 42)))
        let result = try execute(peer: peer)
        #expect(result.argv == Array(request.argv.prefix(3)))
        #expect(result.events == ["attach"])
        #expect(peer.frames.count == 1)
        #expect(try SessionHost.decodeFrame(SessionHost.Request.self, from: peer.frames[0]) == .ensure(request))
        #expect(peer.closed)
    }

    @Test(arguments: [HostFailure.disconnected, .timeout, .invalidIdentity])
    func beforeHandshakeFailureKeepsPayload(_ failure: HostFailure) throws {
        let result = Recorder()
        var connects = 0
        let client = Client(connect: { connects += 1; throw failure }, diagnostic: result.diagnostic, execute: result.execute)
        try client.run(request: request)
        #expect(connects == 1)
        #expect(result.argv == request.argv)
        #expect(result.events == ["attach"])
    }

    @Test func rejectedBeforeCreationKeepsPayload() throws {
        let peer = Peer(reply: .error(.init(stage: .before, message: "unavailable")))
        let result = try execute(peer: peer)
        #expect(result.argv == request.argv)
        #expect(result.events == ["attach"])
        #expect(peer.frames.count == 1)
    }

    @Test(arguments: [HostFailure.timeout, .disconnected])
    func lostReplyNeverReplaysAndDiagnosesBeforeAttach(_ failure: HostFailure) throws {
        let peer = Peer(reply: nil)
        peer.failure = failure
        var executions = 0
        peer.onSend = { executions += 1 }
        let result = try execute(peer: peer)
        #expect(result.argv == Array(request.argv.prefix(3)))
        #expect(result.events == [SessionHost.ClientOutcome.uncertain.diagnostic!, "attach"])
        #expect(executions == 1)
        #expect(peer.closed)
    }

    @Test func partialWriteIsAlreadyUncertain() throws {
        let peer = Peer(reply: nil)
        peer.failSend = true
        let result = try execute(peer: peer)
        #expect(result.argv == Array(request.argv.prefix(3)))
        #expect(result.events.count == 2)
    }

    @Test func startedFailureDiagnosesBeforeAttach() throws {
        let peer = Peer(reply: .error(.init(stage: .started, message: "timeout")))
        let result = try execute(peer: peer)
        #expect(result.argv == Array(request.argv.prefix(3)))
        #expect(result.events == [SessionHost.ClientOutcome.uncertain.diagnostic!, "attach"])
    }

    @Test func oversizedEnvironmentFallsBackWithoutConnecting() throws {
        let large = SessionHost.Ensure(name: request.name, argv: request.argv, cwd: request.cwd,
                                       env: ["LARGE": String(repeating: "x", count: SessionHost.maximumFrameBytes)], rows: request.rows, cols: request.cols)
        let result = Recorder()
        var connects = 0
        let client = Client(connect: { connects += 1; throw HostFailure.disconnected }, diagnostic: result.diagnostic, execute: result.execute)
        try client.run(request: large)
        #expect(connects == 0)
        #expect(result.argv == large.argv)
        #expect(result.env == large.env)
    }

    private var request: SessionHost.Ensure {
        .init(name: "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", argv: ["/bundle/zmx", "attach", "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "/bin/sh", "-c", "side effect"],
              cwd: "/tmp/project", env: ["ZMX_DIR": "/tmp/pane-sockets", "CUSTOM": "one\ntwo"], rows: 43, cols: 132)
    }

    private func execute(peer: Peer) throws -> Recorder {
        let recorder = Recorder()
        let client = Client(connect: { peer }, diagnostic: recorder.diagnostic, execute: recorder.execute)
        try client.run(request: request)
        #expect(recorder.env == request.env)
        return recorder
    }

    private final class Recorder {
        var argv: [String] = []
        var env: [String: String] = [:]
        var events: [String] = []
        func diagnostic(_ message: String) { events.append(message) }
        func execute(_ argv: [String], _ env: [String: String]) { self.argv = argv; self.env = env; events.append("attach") }
    }

    private final class Peer: ClientPeer {
        let reply: SessionHost.Response?
        var frames: [Data] = []
        var closed = false
        var failSend = false
        var failure: HostFailure = .disconnected
        var onSend: (() -> Void)?
        init(reply: SessionHost.Response?) { self.reply = reply }
        func send(_ frame: Data, deadline: TimeInterval) throws {
            frames.append(frame)
            onSend?()
            if failSend { throw failure }
        }
        func receive(deadline: TimeInterval) throws -> SessionHost.Response {
            if let reply { return reply }
            throw failure
        }
        func close() { closed = true }
    }
}
