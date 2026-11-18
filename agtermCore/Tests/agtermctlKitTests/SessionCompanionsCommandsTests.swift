import ArgumentParser
import Foundation
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

    @Test func sessionNewWithRemoteSendsTheRemoteCommand() throws {
        var args = ControlArgs(cwd: "/srv", workspaceName: "dev", host: "mac", command: "top", window: "win")
        args.originWindow = "6f1c"

        let actual = try request(["session", "new", "--remote", "mac", "--origin-window", "6f1c", "--workspace-name", "dev",
                                  "--cwd", "/srv", "--command", "top", "--window", "win"])

        #expect(actual == ControlRequest(cmd: .sessionRemoteNew, args: args))
        #expect(try request(["session", "new", "--remote", "srv"]) == ControlRequest(cmd: .sessionRemoteNew, args: ControlArgs(host: "srv")))
    }

    @Test(arguments: [["--parent", "p1"], ["--workspace", "w"], ["--workspace-name", "w", "--create-workspace"], ["--after", "a"],
                      ["--before", "b"], ["--command", "top", "--wait"], ["--name", "n"], ["--no-select"], ["--tint", "red"],
                      ["--op-id", "op-1", "--epoch", "e1"]])
    func sessionNewWithRemoteRefusesWhatTheRowCannotCarry(extra: [String]) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "new", "--remote", "mac"] + extra) }
    }

    @Test func originWindowNeedsRemote() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "new", "--origin-window", "6f1c"]) }
    }

    @Test func theOriginArgvParsesAsAPlainSessionNewOnTheOrigin() throws {
        let create = RemoteSessionCreate(host: "mac", cwd: "-srv", command: "-x make run")

        let mac = try request(create.arguments(origin: .mac(window: "6f1c"), workspaceName: "-ops"))
        let server = try request(create.arguments(origin: .server, workspaceName: "dev"))

        #expect(mac == ControlRequest(cmd: .sessionNew, args: ControlArgs(
            cwd: "-srv", workspaceName: "-ops", createWorkspace: true, noSelect: true, command: "-x make run", window: "6f1c")))
        #expect(server.cmd == .sessionNew)
        #expect(server.args?.window == nil)
    }

    @Test func anAppThatDoesNotKnowTheRemoteCommandReadsAsTooOld() {
        let unknown = ControlResponse(ok: false, error: "invalid request: unknown cmd session.remote.new")
        let send = companionSend({ _ in SocketReply(response: unknown, raw: Data()) }, json: false,
                                 tooOld: "the running app is too old for remote sessions")
        #expect(throws: ExitCode.self) { try send(ControlRequest(cmd: .sessionRemoteNew, args: ControlArgs(host: "mac"))) }
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

    @Test func sessionConvertWithCompanionSendsTheConvertCommand() throws {
        let expected = ControlRequest(cmd: .sessionCompanionConvert, target: "s1", args: ControlArgs(window: "win"))
        #expect(try request(["session", "convert", "--companion", "--target", "s1", "--window", "win"]) == expected)
        #expect(try request(["session", "convert", "--companion"]) == ControlRequest(cmd: .sessionCompanionConvert, target: "active"))
    }

    @Test func sessionMoveWithParentSendsTheCompanionMoveCommand() throws {
        var args = ControlArgs(window: "win")
        args.parent = "p2"
        args.index = 0
        #expect(try request(["session", "move", "--target", "c1", "--parent", "p2", "--index", "0", "--window", "win"])
            == ControlRequest(cmd: .sessionCompanionMove, target: "c1", args: args))
        let appended = try request(["session", "move", "--parent", "p2"])
        #expect(appended.cmd == .sessionCompanionMove)
        #expect(appended.target == "active")
        #expect(appended.args?.index == nil)
        #expect(try request(["session", "move", "w1", "--target", "c1"]).cmd == .sessionMove)
    }

    @Test func sessionMoveWithParentCarriesItsOperationIdAndEpoch() throws {
        let move = try Session.Move.parse(["--target", "c1", "--parent", "p2", "--op-id", "op-1", "--epoch", "e1"])

        let request = try move.makeRequest()

        #expect(request.cmd == .sessionCompanionMove)
        #expect(request.args?.opID == "op-1")
        #expect(request.args?.epoch == "e1")
    }

    @Test(arguments: [["--index", "1"], ["--parent", "p2", "w1"], ["--parent", "p2", "--to", "up"], ["--parent", "p2", "--after", "a"],
                      ["--parent", "p2", "--before", "b"], ["--parent", "p2", "--target", "c1", "--target", "c2"],
                      ["--parent", "p2", "--index", "-1"]])
    func sessionMoveWithParentRefusesConflictingOptions(extra: [String]) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "move"] + extra) }
    }

    @Test func anAppThatDoesNotKnowTheMoveCommandReadsAsTooOld() {
        let unknown = ControlResponse(ok: false, error: "invalid request: unknown cmd session.companion.move")
        let send = companionSend({ _ in SocketReply(response: unknown, raw: Data()) }, json: false)
        #expect(throws: ExitCode.self) { try send(ControlRequest(cmd: .sessionCompanionMove, target: "c1")) }
        let refused = ControlResponse(ok: false, error: "not a companion")
        let passing = companionSend({ _ in SocketReply(response: refused, raw: Data()) }, json: false)
        #expect((try? passing(ControlRequest(cmd: .sessionCompanionMove, target: "c1")))?.response == refused)
    }

    @Test func sessionConvertNeedsTheCompanionFlag() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "convert"]) }
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

    @Test func anAttachedConvertParsesOnItsOrigin() throws {
        let forward = AttachedForward.convert(session: "s1")

        let parsed = try request(forward.originArgv)

        #expect(parsed == ControlRequest(cmd: .sessionCompanionConvert, target: "s1"))
        #expect(parsed.cmd == forward.command)
    }
}
