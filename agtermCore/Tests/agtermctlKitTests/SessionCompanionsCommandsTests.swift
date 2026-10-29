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

    @Test func sessionDuplicateWithCompanionSendsTheDuplicateCompanionCommand() throws {
        let expected = ControlRequest(cmd: .sessionCompanionDuplicate, target: "p1", args: ControlArgs(window: "win"))
        #expect(try request(["session", "duplicate", "--companion", "--target", "p1", "--window", "win"]) == expected)
        #expect(try request(["session", "duplicate", "--target", "p1"]).cmd == .sessionDuplicate)
        #expect(try request(["session", "duplicate", "--companion", "--no-select"]).args?.noSelect == true)
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "duplicate", "--no-select"]) }
    }

    @Test func overlayPageAttachSendsTheAttachCommandForTheTarget() throws {
        let expected = ControlRequest(cmd: .sessionCompanionPageAttach, target: "pg", args: ControlArgs(window: "win"))
        #expect(try request(["session", "overlay", "page-attach", "--target", "pg", "--window", "win"]) == expected)
    }

    @Test func sessionCollapseAndExpandTargetAParent() throws {
        #expect(try request(["session", "collapse"]) == ControlRequest(cmd: .sessionCollapse, target: "active"))
        let expected = ControlRequest(cmd: .sessionExpand, target: "9f3c", args: ControlArgs(window: "win"))
        #expect(try request(["session", "expand", "--target", "9f3c", "--window", "win"]) == expected)
    }

    @Test func overlayOpenWithCompanionSendsThePageCompanionCommand() throws {
        let actual = try request(["session", "overlay", "open", "--html", "/tmp/p.html", "--companion", "--target", "p1"])
        #expect(actual.cmd == .sessionCompanionPage)
        #expect(actual.target == "p1")
        #expect(actual.args?.html == "/tmp/p.html")
    }

    @Test func anHtmlCompanionMayBlockOnItsPageAndAURLOneMayNot() throws {
        let blocked = try request(["session", "overlay", "open", "--html", "/tmp/p.html", "--companion", "--block"])
        #expect(blocked.cmd == .sessionCompanionPage)
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["session", "overlay", "open", "--url", "http://localhost:1", "--companion", "--block"])
        }
    }

    @Test(arguments: [["--pane", "right"], ["--size-percent", "50"]])
    func overlayOpenWithCompanionRefusesAnythingButFullSize(extra: [String]) {
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["session", "overlay", "open", "--html", "/tmp/p.html", "--companion"] + extra)
        }
    }

    @Test func overlayOpenWithCompanionNeedsAPage() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "overlay", "open", "top", "--companion"]) }
    }
}
