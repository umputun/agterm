import ArgumentParser
import Foundation
import Testing
import agtCore
@testable import agtctlKit

struct CommandsTests {
    /// Parse argv into a subcommand and build its `ControlRequest`. Throws if parsing or request-building fails.
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func tree() throws {
        #expect(try request(["tree"]) == ControlRequest(cmd: .tree))
    }

    @Test func workspaceNewWithName() throws {
        #expect(try request(["workspace", "new", "Work"]) == ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "Work")))
    }

    @Test func workspaceNewWithoutName() throws {
        #expect(try request(["workspace", "new"]) == ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: nil)))
    }

    @Test func workspaceRename() throws {
        let expected = ControlRequest(cmd: .workspaceRename, target: "9f3c", args: ControlArgs(name: "Renamed"))
        #expect(try request(["workspace", "rename", "Renamed", "--target", "9f3c"]) == expected)
    }

    @Test func workspaceDeleteDefaultsActive() throws {
        #expect(try request(["workspace", "delete"]) == ControlRequest(cmd: .workspaceDelete, target: "active"))
    }

    @Test func workspaceSelect() throws {
        #expect(try request(["workspace", "select", "--target", "ab"]) == ControlRequest(cmd: .workspaceSelect, target: "ab"))
    }

    @Test func sessionNewWithCwdAndWorkspace() throws {
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(cwd: "/tmp", workspace: "ws1"))
        #expect(try request(["session", "new", "--cwd", "/tmp", "--workspace", "ws1"]) == expected)
    }

    @Test func sessionClose() throws {
        #expect(try request(["session", "close", "--target", "x"]) == ControlRequest(cmd: .sessionClose, target: "x"))
    }

    @Test func sessionSelectDefaultsActive() throws {
        #expect(try request(["session", "select"]) == ControlRequest(cmd: .sessionSelect, target: "active"))
    }

    @Test func sessionRename() throws {
        let expected = ControlRequest(cmd: .sessionRename, target: "active", args: ControlArgs(name: "build"))
        #expect(try request(["session", "rename", "build"]) == expected)
    }

    @Test func sessionMove() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "s1", args: ControlArgs(workspace: "ws2"))
        #expect(try request(["session", "move", "ws2", "--target", "s1"]) == expected)
    }

    @Test func sessionTypeWithText() throws {
        let expected = ControlRequest(cmd: .sessionType, target: "active", args: ControlArgs(text: "ls\n", select: false))
        #expect(try request(["session", "type", "ls\n"]) == expected)
    }

    @Test func sessionTypeWithSelect() throws {
        let expected = ControlRequest(cmd: .sessionType, target: "s1", args: ControlArgs(text: "hi", select: true))
        #expect(try request(["session", "type", "hi", "--target", "s1", "--select"]) == expected)
    }

    @Test func sessionTypeStdinFlagParses() throws {
        // the --stdin flag parses (we don't call makeRequest here — it would block reading stdin).
        let command = try Session.TypeText.parse(["--stdin", "--target", "s1"])
        #expect(command.stdin)
        #expect(command.text == nil)
        #expect(command.target.target == "s1")
    }

    @Test func sessionSplitDefaultsToggle() throws {
        let expected = ControlRequest(cmd: .sessionSplit, target: "active", args: ControlArgs(mode: "toggle"))
        #expect(try request(["session", "split"]) == expected)
    }

    @Test func sessionSplitOn() throws {
        let expected = ControlRequest(cmd: .sessionSplit, target: "active", args: ControlArgs(mode: "on"))
        #expect(try request(["session", "split", "on"]) == expected)
    }

    @Test func sessionCopyDefaultsActive() throws {
        #expect(try request(["session", "copy"]) == ControlRequest(cmd: .sessionCopy, target: "active"))
    }

    @Test func sessionCopyWithTarget() throws {
        #expect(try request(["session", "copy", "--target", "9f3c"]) == ControlRequest(cmd: .sessionCopy, target: "9f3c"))
    }

    @Test func sessionOverlayOpenWithCommandAndCwd() throws {
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c",
                                      args: ControlArgs(cwd: "/b", command: "revdiff"))
        #expect(try request(["session", "overlay", "open", "revdiff", "--cwd", "/b", "--target", "9f3c"]) == expected)
    }

    @Test func sessionOverlayOpenDefaultsActiveNoCwd() throws {
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active", args: ControlArgs(command: "revdiff"))
        #expect(try request(["session", "overlay", "open", "revdiff"]) == expected)
    }

    @Test func sessionOverlayOpenWithWait() throws {
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active",
                                      args: ControlArgs(command: "revdiff", wait: true))
        #expect(try request(["session", "overlay", "open", "revdiff", "--wait"]) == expected)
    }

    @Test func sessionOverlayClose() throws {
        #expect(try request(["session", "overlay", "close"]) == ControlRequest(cmd: .sessionOverlayClose, target: "active"))
    }

    @Test func quickDefaultsToggle() throws {
        #expect(try request(["quick"]) == ControlRequest(cmd: .quick, args: ControlArgs(mode: "toggle")))
    }

    @Test func quickShow() throws {
        #expect(try request(["quick", "show"]) == ControlRequest(cmd: .quick, args: ControlArgs(mode: "show")))
    }

    @Test func fontInc() throws {
        #expect(try request(["font", "inc", "--target", "s1"]) == ControlRequest(cmd: .fontInc, target: "s1"))
    }

    @Test func fontDec() throws {
        #expect(try request(["font", "dec"]) == ControlRequest(cmd: .fontDec, target: "active"))
    }

    @Test func fontReset() throws {
        #expect(try request(["font", "reset"]) == ControlRequest(cmd: .fontReset, target: "active"))
    }

    @Test func statusbarOff() throws {
        #expect(try request(["statusbar", "off"]) == ControlRequest(cmd: .statusbar, args: ControlArgs(mode: "off")))
    }

    @Test func invalidSubcommandFailsToParse() {
        #expect(throws: (any Error).self) { try Agtctl.parseAsRoot(["bogus"]) }
    }

    @Test func sessionTypeWithoutTextOrStdinFails() throws {
        // parses fine (text is optional), but makeRequest validates it needs TEXT or --stdin.
        let parsed = try Agtctl.parseAsRoot(["session", "type"])
        let command = try #require(parsed as? any RequestCommand)
        #expect(throws: (any Error).self) { try command.makeRequest() }
    }

    // MARK: - socket-path precedence

    @Test func socketPathExplicitFlagWins() throws {
        let command = try Tree.parse(["--socket", "/tmp/explicit.sock"])
        let env = ["AGT_STATE_DIR": "/tmp/state", "HOME": "/Users/x"]
        #expect(command.options.socketPath(env: env) == "/tmp/explicit.sock")
    }

    @Test func socketPathStateDirOverHome() throws {
        let command = try Tree.parse([])
        let env = ["AGT_STATE_DIR": "/tmp/state", "HOME": "/Users/x"]
        #expect(command.options.socketPath(env: env) == "/tmp/state/agt.sock")
    }

    @Test func socketPathFallsBackToHome() throws {
        let command = try Tree.parse([])
        let env = ["HOME": "/Users/x"]
        #expect(command.options.socketPath(env: env) == "/Users/x/Library/Application Support/agt/agt.sock")
    }

    @Test func socketPathFallsBackToTmpWithoutHome() throws {
        let command = try Tree.parse([])
        #expect(command.options.socketPath(env: [:]) == "/tmp/agt/agt.sock")
    }
}
