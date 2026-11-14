import ArgumentParser
import Testing
import agtermCore
@testable import agtermctlKit

struct SessionRestartCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func carriesLinePaneAndToken() throws {
        let expected = ControlRequest(cmd: .sessionRestart, target: "s1",
                                      args: ControlArgs(command: "cld 'brief one'", window: "w1", pane: "right", paneID: "tok"))
        #expect(try request(["session", "restart", "--target", "s1", "--pane", "right", "--pane-id", "tok",
                             "--command", "cld 'brief one'", "--window", "w1"]) == expected)
    }

    @Test func omitsTheLineToAskForAReplay() throws {
        let expected = ControlRequest(cmd: .sessionRestart, target: "s1", args: ControlArgs(paneID: "tok"))
        #expect(try request(["session", "restart", "--target", "s1", "--pane-id", "tok"]) == expected)
    }

    @Test func sendsAnEmptyLineForTheServerToRefuse() throws {
        let expected = ControlRequest(cmd: .sessionRestart, target: "active", args: ControlArgs(command: "", paneID: "tok"))
        #expect(try request(["session", "restart", "--pane-id", "tok", "--command", ""]) == expected)
    }

    @Test(arguments: [
        ["session", "restart", "--command", "cld"],
        ["session", "restart"],
        ["session", "restart", "--command", "cld", "--pane", "middle"],
    ])
    func requiresAValidPaneSelector(argv: [String]) {
        #expect(throws: (any Error).self) { try request(argv) }
    }

    @Test(arguments: ["-x" as String?, nil])
    func anAttachedRestartParsesOnItsOrigin(command: String?) throws {
        let forward = AttachedForward.restart(session: "s1", paneID: "tok", command: command)

        let parsed = try request(forward.originArgv)

        #expect(parsed == ControlRequest(cmd: .sessionRestart, target: "s1", args: ControlArgs(command: command, paneID: "tok")))
        #expect(parsed.cmd == forward.command)
    }
}
