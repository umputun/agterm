import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct CommandsTests {
    /// Parse argv into a subcommand and build its `ControlRequest`. Throws if parsing or request-building fails.
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    /// Parses argv expecting a validation failure and returns the user-facing message, or nil when it parses.
    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Agtermctl.parseAsRoot(argv)
            return nil
        } catch {
            return Agtermctl.message(for: error)
        }
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

    @Test func workspaceMove() throws {
        let expected = ControlRequest(cmd: .workspaceMove, target: "active", args: ControlArgs(to: "top"))
        #expect(try request(["workspace", "move", "--to", "top"]) == expected)
    }

    @Test func workspaceMoveRequiresToFails() {
        // --to has no default, so omitting it must fail to parse (the direction is validated server-side).
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["workspace", "move"]) }
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

    @Test func sessionMoveReorder() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "active", args: ControlArgs(to: "up"))
        #expect(try request(["session", "move", "--to", "up"]) == expected)
    }

    @Test func sessionMoveRequiresWorkspaceOrTo() {
        // neither the workspace positional nor --to is set — validate() rejects it with a usage message.
        #expect(validationMessage(["session", "move"]) == "provide a destination workspace or --to")
    }

    @Test func sessionMoveRejectsWorkspaceAndTo() {
        // both the workspace positional and --to are set — validate() rejects it with a usage message.
        #expect(validationMessage(["session", "move", "ws2", "--to", "up"]) == "provide a destination workspace or --to, not both")
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

    @Test func sessionScratchDefaultsToggle() throws {
        let expected = ControlRequest(cmd: .sessionScratch, target: "active", args: ControlArgs(mode: "toggle"))
        #expect(try request(["session", "scratch"]) == expected)
    }

    @Test func sessionScratchOff() throws {
        let expected = ControlRequest(cmd: .sessionScratch, target: "active", args: ControlArgs(mode: "off"))
        #expect(try request(["session", "scratch", "off"]) == expected)
    }

    @Test func sessionFocusDefaultsOther() throws {
        let expected = ControlRequest(cmd: .sessionFocus, target: "active", args: ControlArgs(pane: "other"))
        #expect(try request(["session", "focus"]) == expected)
    }

    @Test func sessionFocusRight() throws {
        let expected = ControlRequest(cmd: .sessionFocus, target: "active", args: ControlArgs(pane: "right"))
        #expect(try request(["session", "focus", "right"]) == expected)
    }

    @Test func sessionGoNext() throws {
        let expected = ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "next"))
        #expect(try request(["session", "go", "--to", "next"]) == expected)
    }

    @Test func sessionGoPrev() throws {
        let expected = ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "prev"))
        #expect(try request(["session", "go", "--to", "prev"]) == expected)
    }

    @Test func sessionGoWithWindow() throws {
        let expected = ControlRequest(cmd: .sessionGo, args: ControlArgs(window: "w1", to: "last"))
        #expect(try request(["session", "go", "--to", "last", "--window", "w1"]) == expected)
    }

    @Test func sessionGoRequiresToFails() {
        // --to has no default, so omitting it must fail to parse (the direction is validated server-side).
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "go"]) }
    }

    @Test func notifyDefaultsActiveNoTitle() throws {
        let expected = ControlRequest(cmd: .notify, target: "active", args: ControlArgs(body: "hi"))
        #expect(try request(["notify", "hi"]) == expected)
    }

    @Test func notifyWithTitleAndTarget() throws {
        let expected = ControlRequest(cmd: .notify, target: "build", args: ControlArgs(title: "Build", body: "done"))
        #expect(try request(["notify", "done", "--title", "Build", "--target", "build"]) == expected)
    }

    @Test func sessionCopyDefaultsActive() throws {
        #expect(try request(["session", "copy"]) == ControlRequest(cmd: .sessionCopy, target: "active"))
    }

    @Test func sessionCopyWithTarget() throws {
        #expect(try request(["session", "copy", "--target", "9f3c"]) == ControlRequest(cmd: .sessionCopy, target: "9f3c"))
    }

    @Test func sessionStatusWithBlink() throws {
        let req = try request(["session", "status", "active", "--blink"])
        #expect(req.cmd == .sessionStatus)
        #expect(req.args?.status == "active")
        #expect(req.args?.blink == true)
        #expect(req == ControlRequest(cmd: .sessionStatus, target: "active", args: ControlArgs(status: "active", blink: true)))
    }

    @Test func sessionStatusWithoutBlink() throws {
        let req = try request(["session", "status", "completed", "--target", "s1"])
        #expect(req.cmd == .sessionStatus)
        #expect(req.args?.status == "completed")
        #expect(req.args?.blink == nil)
        #expect(req.args?.autoReset == nil)
        #expect(req == ControlRequest(cmd: .sessionStatus, target: "s1", args: ControlArgs(status: "completed")))
    }

    @Test func sessionStatusWithAutoReset() throws {
        let req = try request(["session", "status", "completed", "--auto-reset"])
        #expect(req.cmd == .sessionStatus)
        #expect(req.args?.status == "completed")
        #expect(req.args?.autoReset == true)
        #expect(req == ControlRequest(cmd: .sessionStatus, target: "active",
                                      args: ControlArgs(status: "completed", autoReset: true)))
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

    @Test func sessionOverlayOpenFloating() throws {
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active",
                                      args: ControlArgs(command: "htop", sizePercent: 70))
        #expect(try request(["session", "overlay", "open", "htop", "--size-percent", "70"]) == expected)
    }

    @Test func sessionOverlayClose() throws {
        #expect(try request(["session", "overlay", "close"]) == ControlRequest(cmd: .sessionOverlayClose, target: "active"))
    }

    @Test func sessionOverlayOpenWithBlockParses() throws {
        // --block changes run() (open → poll result), not makeRequest, so the built request is the plain open.
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active", args: ControlArgs(command: "revdiff"))
        #expect(try request(["session", "overlay", "open", "revdiff", "--block"]) == expected)
    }

    @Test func sessionOverlayOpenWithBlockAndSizePercentParses() throws {
        // --block composes with --size-percent; the block run() opens via makeRequest, so sizePercent rides through.
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active",
                                      args: ControlArgs(command: "htop", sizePercent: 60))
        #expect(try request(["session", "overlay", "open", "htop", "--block", "--size-percent", "60"]) == expected)
    }

    @Test func sessionOverlayResult() throws {
        #expect(try request(["session", "overlay", "result", "--target", "9f3c"])
            == ControlRequest(cmd: .sessionOverlayResult, target: "9f3c"))
    }

    @Test func sessionOverlayBlockRejectsWait() {
        // validate() enforces the mutually-exclusive flags at parse time (before any connection).
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["session", "overlay", "open", "cmd", "--block", "--wait"])
        }
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

    @Test func keymapReload() throws {
        #expect(try request(["keymap", "reload"]) == ControlRequest(cmd: .keymapReload))
    }

    @Test func keymapReloadRejectsWindowSelector() {
        // keymap.reload is app-global, so --window is meaningless and must not be accepted.
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["keymap", "reload", "--window", "w1"]) }
    }

    // MARK: - window subcommands

    @Test func windowNewWithName() throws {
        #expect(try request(["window", "new", "Work"]) == ControlRequest(cmd: .windowNew, args: ControlArgs(name: "Work")))
    }

    @Test func windowNewWithoutName() throws {
        #expect(try request(["window", "new"]) == ControlRequest(cmd: .windowNew, args: ControlArgs(name: nil)))
    }

    @Test func windowList() throws {
        #expect(try request(["window", "list"]) == ControlRequest(cmd: .windowList))
    }

    @Test func windowSelect() throws {
        #expect(try request(["window", "select", "9f3c"]) == ControlRequest(cmd: .windowSelect, target: "9f3c"))
    }

    @Test func windowSelectDefaultsActive() throws {
        #expect(try request(["window", "select"]) == ControlRequest(cmd: .windowSelect, target: "active"))
    }

    @Test func windowClose() throws {
        #expect(try request(["window", "close", "ab"]) == ControlRequest(cmd: .windowClose, target: "ab"))
    }

    @Test func windowRename() throws {
        let expected = ControlRequest(cmd: .windowRename, target: "9f3c", args: ControlArgs(name: "Renamed"))
        #expect(try request(["window", "rename", "9f3c", "Renamed"]) == expected)
    }

    @Test func windowDelete() throws {
        #expect(try request(["window", "delete", "9f3c"]) == ControlRequest(cmd: .windowDelete, target: "9f3c"))
    }

    @Test func windowResize() throws {
        let expected = ControlRequest(cmd: .windowResize, target: "9f3c", args: ControlArgs(width: 1200, height: 800))
        #expect(try request(["window", "resize", "9f3c", "--width", "1200", "--height", "800"]) == expected)
    }

    @Test func windowResizeDefaultsToActive() throws {
        let expected = ControlRequest(cmd: .windowResize, target: "active", args: ControlArgs(width: 1000, height: 700))
        #expect(try request(["window", "resize", "--width", "1000", "--height", "700"]) == expected)
    }

    @Test func windowMoveWithDisplay() throws {
        let expected = ControlRequest(cmd: .windowMove, target: "9f3c", args: ControlArgs(x: 100, y: 50, display: 1))
        #expect(try request(["window", "move", "9f3c", "--x", "100", "--y", "50", "--display", "1"]) == expected)
    }

    @Test func windowMoveDefaultsActiveAndCurrentDisplay() throws {
        let expected = ControlRequest(cmd: .windowMove, target: "active", args: ControlArgs(x: 100, y: 50))
        #expect(try request(["window", "move", "--x", "100", "--y", "50"]) == expected)
    }

    @Test func windowDeleteDefaultsActive() throws {
        #expect(try request(["window", "delete"]) == ControlRequest(cmd: .windowDelete, target: "active"))
    }

    @Test func windowRenameRequiresBothArgsFails() {
        // rename needs an id AND a name; only one positional must fail to parse.
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "rename", "9f3c"]) }
    }

    @Test func windowCommandsRejectWindowSelector() {
        // window.* target via the positional id, so --window is meaningless and must not be accepted.
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "list", "--window", "w1"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "select", "9f3c", "--window", "w1"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["quick", "--window", "w1"]) }
    }

    @Test func windowCommandsKeepSocketAndJSON() throws {
        // --socket / --json stay available on window.* (they share the connection/print surface).
        let parsed = try Agtermctl.parseAsRoot(["window", "list", "--socket", "/tmp/x.sock", "--json"])
        let command = try #require(parsed as? Window.List)
        #expect(command.options.json)
        #expect(command.options.socketPath(env: [:]) == "/tmp/x.sock")
    }

    // MARK: - global --window selector

    @Test func sessionNewWithWindow() throws {
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(workspace: nil, window: "w1"))
        #expect(try request(["session", "new", "--window", "w1"]) == expected)
    }

    @Test func sessionSelectWithWindow() throws {
        let expected = ControlRequest(cmd: .sessionSelect, target: "active", args: ControlArgs(window: "w1"))
        #expect(try request(["session", "select", "--window", "w1"]) == expected)
    }

    @Test func workspaceNewWithWindow() throws {
        let expected = ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "Work", window: "w1"))
        #expect(try request(["workspace", "new", "Work", "--window", "w1"]) == expected)
    }

    @Test func treeWithWindow() throws {
        #expect(try request(["tree", "--window", "w1"]) == ControlRequest(cmd: .tree, args: ControlArgs(window: "w1")))
    }

    @Test func treeWithoutWindowOmitsArgs() throws {
        // no --window keeps tree in its compact form (args nil), matching the no-window request value.
        #expect(try request(["tree"]) == ControlRequest(cmd: .tree))
    }

    // --window must populate args.window AND leave the command's own args intact (the merge folds it
    // into the existing bag rather than replacing it).

    @Test func sessionTypeWithWindow() throws {
        let expected = ControlRequest(cmd: .sessionType, target: "active",
                                      args: ControlArgs(text: "ls\n", select: false, window: "w1"))
        #expect(try request(["session", "type", "ls\n", "--window", "w1"]) == expected)
    }

    @Test func sessionMoveWithWindow() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "s1", args: ControlArgs(workspace: "ws2", window: "w1"))
        #expect(try request(["session", "move", "ws2", "--target", "s1", "--window", "w1"]) == expected)
    }

    @Test func sessionRenameWithWindow() throws {
        let expected = ControlRequest(cmd: .sessionRename, target: "active", args: ControlArgs(name: "build", window: "w1"))
        #expect(try request(["session", "rename", "build", "--window", "w1"]) == expected)
    }

    @Test func sessionCloseWithWindow() throws {
        #expect(try request(["session", "close", "--target", "x", "--window", "w1"])
            == ControlRequest(cmd: .sessionClose, target: "x", args: ControlArgs(window: "w1")))
    }

    @Test func workspaceRenameWithWindow() throws {
        let expected = ControlRequest(cmd: .workspaceRename, target: "9f3c", args: ControlArgs(name: "Renamed", window: "w1"))
        #expect(try request(["workspace", "rename", "Renamed", "--target", "9f3c", "--window", "w1"]) == expected)
    }

    @Test func fontIncWithWindow() throws {
        #expect(try request(["font", "inc", "--window", "w1"])
            == ControlRequest(cmd: .fontInc, target: "active", args: ControlArgs(window: "w1")))
    }

    @Test func fontDecWithWindow() throws {
        #expect(try request(["font", "dec", "--target", "s1", "--window", "w1"])
            == ControlRequest(cmd: .fontDec, target: "s1", args: ControlArgs(window: "w1")))
    }

    @Test func fontResetWithWindow() throws {
        #expect(try request(["font", "reset", "--window", "w1"])
            == ControlRequest(cmd: .fontReset, target: "active", args: ControlArgs(window: "w1")))
    }

    @Test func invalidSubcommandFailsToParse() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["bogus"]) }
    }

    @Test func sessionTypeWithoutTextOrStdinFails() throws {
        // parses fine (text is optional), but makeRequest validates it needs TEXT or --stdin.
        let parsed = try Agtermctl.parseAsRoot(["session", "type"])
        let command = try #require(parsed as? any RequestCommand)
        #expect(throws: (any Error).self) { try command.makeRequest() }
    }

    // MARK: - socket-path precedence

    @Test func socketPathExplicitFlagWins() throws {
        let command = try Tree.parse(["--socket", "/tmp/explicit.sock"])
        let env = ["AGTERM_STATE_DIR": "/tmp/state", "HOME": "/Users/x"]
        #expect(command.options.socketPath(env: env) == "/tmp/explicit.sock")
    }

    @Test func socketPathStateDirOverHome() throws {
        let command = try Tree.parse([])
        let env = ["AGTERM_STATE_DIR": "/tmp/state", "HOME": "/Users/x"]
        #expect(command.options.socketPath(env: env) == "/tmp/state/agterm.sock")
    }

    @Test func socketPathFallsBackToHome() throws {
        let command = try Tree.parse([])
        let env = ["HOME": "/Users/x"]
        #expect(command.options.socketPath(env: env) == "/Users/x/Library/Application Support/agterm/agterm.sock")
    }

    @Test func socketPathFallsBackToTmpWithoutHome() throws {
        let command = try Tree.parse([])
        #expect(command.options.socketPath(env: [:]) == "/tmp/agterm/agterm.sock")
    }
}
