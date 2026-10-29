import ArgumentParser
import Testing
import agtermCore
@testable import agtermctlKit

struct SessionCompanionsCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func sessionNewWithParentSendsTheCompanionCommand() throws {
        let expected = ControlRequest(cmd: .sessionCompanionNew, target: "p1", args: ControlArgs(
            name: "logs", cwd: "/tmp", noSelect: true, command: "top", wait: true, window: "win", tint: "red"))
        let actual = try request(["session", "new", "--parent", "p1", "--cwd", "/tmp", "--name", "logs", "--command", "top",
                                  "--wait", "--no-select", "--tint", "red", "--window", "win"])
        #expect(actual == expected)
    }

    @Test(arguments: [["--workspace", "w"], ["--workspace-name", "w"], ["--after", "a"], ["--before", "b"]])
    func sessionNewWithParentRefusesPlacement(extra: [String]) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "new", "--parent", "p1"] + extra) }
    }

    @Test func sessionCollapseAndExpandTargetAParent() throws {
        #expect(try request(["session", "collapse"]) == ControlRequest(cmd: .sessionCollapse, target: "active"))
        let expected = ControlRequest(cmd: .sessionExpand, target: "9f3c", args: ControlArgs(window: "win"))
        #expect(try request(["session", "expand", "--target", "9f3c", "--window", "win"]) == expected)
    }
}
