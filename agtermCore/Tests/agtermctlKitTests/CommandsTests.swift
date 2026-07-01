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

    @Test func workspaceFocusDefaultsToggle() throws {
        #expect(try request(["workspace", "focus"]) == ControlRequest(cmd: .workspaceFocus, target: "active", args: ControlArgs(mode: "toggle")))
    }

    @Test func workspaceFocusOnWithTarget() throws {
        let expected = ControlRequest(cmd: .workspaceFocus, target: "9f3c", args: ControlArgs(mode: "on"))
        #expect(try request(["workspace", "focus", "on", "--target", "9f3c"]) == expected)
    }

    @Test func workspaceFocusRejectsBadMode() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["workspace", "focus", "sideways"]) }
    }

    @Test func sessionNewWithCwdAndWorkspace() throws {
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(cwd: "/tmp", workspace: "ws1"))
        #expect(try request(["session", "new", "--cwd", "/tmp", "--workspace", "ws1"]) == expected)
    }

    @Test func sessionNewWithWorkspaceName() throws {
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(workspaceName: "servers"))
        #expect(try request(["session", "new", "--workspace-name", "servers"]) == expected)
    }

    @Test func sessionNewWithCreateWorkspace() throws {
        // --create-workspace sets createWorkspace=true on the wire (omitted when the flag is absent).
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(workspaceName: "servers", createWorkspace: true))
        #expect(try request(["session", "new", "--workspace-name", "servers", "--create-workspace"]) == expected)
    }

    @Test func sessionNewRejectsWorkspaceAndWorkspaceName() {
        // both addressing modes set — validate() rejects it before any request is built.
        #expect(validationMessage(["session", "new", "--workspace", "active", "--workspace-name", "servers"])
            == "use either --workspace or --workspace-name, not both")
    }

    @Test func sessionNewRequiresWorkspaceNameForCreateWorkspace() {
        // --create-workspace with no --workspace-name has nothing to create by id — validate() rejects it.
        #expect(validationMessage(["session", "new", "--create-workspace"]) == "--create-workspace requires --workspace-name")
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

    @Test func sessionResizeAbsolute() throws {
        let expected = ControlRequest(cmd: .sessionResize, target: "active", args: ControlArgs(ratio: 0.7))
        #expect(try request(["session", "resize", "--split-ratio", "0.7"]) == expected)
    }

    @Test func sessionResizeGrowLeftIsPositiveDelta() throws {
        let expected = ControlRequest(cmd: .sessionResize, target: "active", args: ControlArgs(ratioDelta: 0.05))
        #expect(try request(["session", "resize", "--grow-left", "0.05"]) == expected)
    }

    @Test func sessionResizeGrowRightIsNegativeDelta() throws {
        let expected = ControlRequest(cmd: .sessionResize, target: "active", args: ControlArgs(ratioDelta: -0.05))
        #expect(try request(["session", "resize", "--grow-right", "0.05"]) == expected)
    }

    @Test func sessionResizeRequiresExactlyOneForm() {
        // neither form set, and two forms set — validate() rejects both with the same usage message.
        #expect(validationMessage(["session", "resize"])?.contains("exactly one") == true)
        #expect(validationMessage(["session", "resize", "--split-ratio", "0.7", "--grow-left", "0.1"])?
            .contains("exactly one") == true)
    }

    @Test func sessionResizeRejectsNonFinite() {
        // nan/inf parse as Double but can't JSON-encode; validate() rejects them with a clean usage error.
        #expect(validationMessage(["session", "resize", "--split-ratio", "nan"])?.contains("finite") == true)
        #expect(validationMessage(["session", "resize", "--grow-left", "inf"])?.contains("finite") == true)
        #expect(validationMessage(["session", "resize", "--split-ratio", "1e999"])?.contains("finite") == true)
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

    @Test func sessionTextDefaultsActive() throws {
        // bare `session text` reads the visible screen of the focused pane (no args beyond the base bag).
        #expect(try request(["session", "text"]) == ControlRequest(cmd: .sessionText, target: "active", args: ControlArgs()))
    }

    @Test func sessionTextWithAll() throws {
        let expected = ControlRequest(cmd: .sessionText, target: "active", args: ControlArgs(all: true))
        #expect(try request(["session", "text", "--all"]) == expected)
    }

    @Test func sessionTextWithLines() throws {
        let expected = ControlRequest(cmd: .sessionText, target: "active", args: ControlArgs(lines: 50))
        #expect(try request(["session", "text", "--lines", "50"]) == expected)
    }

    @Test func sessionTextWithPaneAndTarget() throws {
        let expected = ControlRequest(cmd: .sessionText, target: "9f3c", args: ControlArgs(pane: "right"))
        #expect(try request(["session", "text", "--pane", "right", "--target", "9f3c"]) == expected)
    }

    @Test func sessionTextRejectsAllWithLines() {
        #expect(validationMessage(["session", "text", "--all", "--lines", "10"]) == "use either --all or --lines, not both")
    }

    @Test func sessionTextRejectsZeroLines() {
        // a negative --lines (`-5`) is intercepted by ArgumentParser as a flag before validate() runs, so
        // 0 is the CLI-reachable non-positive case the validation guards against.
        #expect(validationMessage(["session", "text", "--lines", "0"]) == "--lines must be greater than 0")
    }

    @Test func sessionTextRejectsBadPane() {
        #expect(validationMessage(["session", "text", "--pane", "other"]) == "--pane must be left or right")
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

    @Test func sessionStatusWithSound() throws {
        let req = try request(["session", "status", "blocked", "--sound", "Glass"])
        #expect(req.cmd == .sessionStatus)
        #expect(req.args?.status == "blocked")
        #expect(req.args?.sound == "Glass")
        #expect(req == ControlRequest(cmd: .sessionStatus, target: "active",
                                      args: ControlArgs(status: "blocked", sound: "Glass")))
    }

    @Test func sessionStatusWithoutSound() throws {
        let req = try request(["session", "status", "active"])
        #expect(req.args?.sound == nil)
    }

    @Test func sessionSearchWithNeedle() throws {
        let expected = ControlRequest(cmd: .sessionSearch, target: "active", args: ControlArgs(text: "error"))
        #expect(try request(["session", "search", "error"]) == expected)
    }

    @Test func sessionSearchOpensWithoutNeedleOrFlag() throws {
        // a bare `session search` opens the bar: no needle, no direction (an empty args bag, since the
        // command always passes a base ControlArgs to withWindow).
        let expected = ControlRequest(cmd: .sessionSearch, target: "active", args: ControlArgs())
        #expect(try request(["session", "search"]) == expected)
    }

    @Test func sessionSearchNext() throws {
        let expected = ControlRequest(cmd: .sessionSearch, target: "active", args: ControlArgs(to: "next"))
        #expect(try request(["session", "search", "--next"]) == expected)
    }

    @Test func sessionSearchPrev() throws {
        let expected = ControlRequest(cmd: .sessionSearch, target: "active", args: ControlArgs(to: "prev"))
        #expect(try request(["session", "search", "--prev"]) == expected)
    }

    @Test func sessionSearchClose() throws {
        let expected = ControlRequest(cmd: .sessionSearch, target: "s1", args: ControlArgs(to: "close"))
        #expect(try request(["session", "search", "--close", "--target", "s1"]) == expected)
    }

    @Test func sessionSearchNeedleWithNext() throws {
        let expected = ControlRequest(cmd: .sessionSearch, target: "active", args: ControlArgs(text: "foo", to: "next"))
        #expect(try request(["session", "search", "foo", "--next"]) == expected)
    }

    @Test(arguments: [["--next", "--close"], ["--next", "--prev"], ["--prev", "--close"]])
    func sessionSearchRejectsFlagCombos(_ flags: [String]) {
        // the three navigation flags are mutually exclusive — validate() rejects combining any two.
        #expect(validationMessage(["session", "search"] + flags) == "--next, --prev, and --close are mutually exclusive")
    }

    @Test func sessionSearchRejectsNeedleWithClose() {
        // --close ignores the needle, so the combo is a usage error rather than a silent no-op.
        #expect(validationMessage(["session", "search", "foo", "--close"]) == "--close cannot be combined with a needle")
    }

    @Test func sessionSearchWithWindow() throws {
        let expected = ControlRequest(cmd: .sessionSearch, target: "active", args: ControlArgs(text: "foo", window: "w1"))
        #expect(try request(["session", "search", "foo", "--window", "w1"]) == expected)
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

    @Test func sidebarDefaultsToggle() throws {
        #expect(try request(["sidebar"]) == ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "toggle")))
    }

    @Test func sidebarHide() throws {
        #expect(try request(["sidebar", "hide"]) == ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "hide")))
    }

    @Test func sidebarModeDefaultsToggle() throws {
        #expect(try request(["sidebar", "mode"]) == ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "toggle")))
    }

    @Test func sidebarModeFlagged() throws {
        #expect(try request(["sidebar", "mode", "flagged"]) == ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "flagged")))
    }

    @Test func sidebarModeRejectsBadMode() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["sidebar", "mode", "sideways"]) }
    }

    @Test func sidebarExpand() throws {
        #expect(try request(["sidebar", "expand"]) == ControlRequest(cmd: .sidebarExpand))
    }

    @Test func sidebarCollapse() throws {
        #expect(try request(["sidebar", "collapse"]) == ControlRequest(cmd: .sidebarCollapse))
    }

    @Test func sidebarExpandWithWindow() throws {
        #expect(try request(["sidebar", "expand", "--window", "abc"]) ==
            ControlRequest(cmd: .sidebarExpand, args: ControlArgs(window: "abc")))
    }

    @Test func sidebarCollapseWithWindow() throws {
        #expect(try request(["sidebar", "collapse", "--window", "abc"]) ==
            ControlRequest(cmd: .sidebarCollapse, args: ControlArgs(window: "abc")))
    }

    @Test func sessionFlagDefaultsToggle() throws {
        #expect(try request(["session", "flag"]) == ControlRequest(cmd: .sessionFlag, target: "active", args: ControlArgs(mode: "toggle")))
    }

    @Test func sessionFlagOnWithTarget() throws {
        let expected = ControlRequest(cmd: .sessionFlag, target: "9f3c", args: ControlArgs(mode: "on"))
        #expect(try request(["session", "flag", "on", "--target", "9f3c"]) == expected)
    }

    @Test func sessionFlagClear() throws {
        #expect(try request(["session", "flag", "clear"]) == ControlRequest(cmd: .sessionFlag, target: "active", args: ControlArgs(mode: "clear")))
    }

    @Test func sessionFlagRejectsBadMode() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "flag", "bogus"]) }
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

    @Test func configReload() throws {
        #expect(try request(["config", "reload"]) == ControlRequest(cmd: .configReload))
    }

    @Test func configReloadRejectsWindowSelector() {
        // config.reload is app-global, so --window is meaningless and must not be accepted.
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["config", "reload", "--window", "w1"]) }
    }

    // MARK: - theme subcommands

    @Test func themeSetWithName() throws {
        #expect(try request(["theme", "set", "Dracula"]) == ControlRequest(cmd: .themeSet, args: ControlArgs(name: "Dracula")))
    }

    @Test func themeSetWithoutNameSelectsDefault() throws {
        #expect(try request(["theme", "set"]) == ControlRequest(cmd: .themeSet, args: ControlArgs(name: nil)))
    }

    @Test func themeList() throws {
        #expect(try request(["theme", "list"]) == ControlRequest(cmd: .themeList))
    }

    @Test func themeRejectsWindowSelector() {
        // theme is app-global (one settings model), so --window is meaningless and must not be accepted.
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["theme", "set", "Nord", "--window", "w1"]) }
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

    // MARK: - session background

    @Test func sessionBackgroundImage() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "active",
                                      args: ControlArgs(mode: "image", path: "/tmp/bg.png"))
        #expect(try request(["session", "background", "image", "/tmp/bg.png"]) == expected)
    }

    @Test func sessionBackgroundImageWithOptions() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "s1",
                                      args: ControlArgs(mode: "image", path: "/tmp/bg.png", opacity: 0.2,
                                                        fit: "cover", position: "top-left", repeats: true))
        let argv = ["session", "background", "image", "/tmp/bg.png", "--opacity", "0.2",
                    "--fit", "cover", "--position", "top-left", "--repeat", "--target", "s1"]
        #expect(try request(argv) == expected)
    }

    @Test func sessionBackgroundText() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "active",
                                      args: ControlArgs(text: "DRAFT", mode: "text", color: "#ff0000", opacity: 0.15))
        let argv = ["session", "background", "text", "DRAFT", "--color", "#ff0000", "--opacity", "0.15"]
        #expect(try request(argv) == expected)
    }

    @Test func sessionBackgroundColor() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "s1",
                                      args: ControlArgs(mode: "color", color: "#112233"))
        #expect(try request(["session", "background", "color", "#112233", "--target", "s1"]) == expected)
    }

    @Test func sessionBackgroundColorRejectsBadColor() {
        // assert the color validation (not some unrelated parse error) fired.
        #expect(validationMessage(["session", "background", "color", "red"])?.contains("color") == true)
        #expect(validationMessage(["session", "background", "color", "#fff"])?.contains("color") == true)
    }

    @Test func sessionBackgroundClear() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "active", args: ControlArgs(mode: "clear"))
        #expect(try request(["session", "background", "clear"]) == expected)
    }

    @Test func sessionBackgroundRejectsBadFit() {
        #expect(validationMessage(["session", "background", "image", "/tmp/bg.png", "--fit", "fill"]) != nil)
    }

    @Test func sessionBackgroundRejectsBadPosition() {
        #expect(validationMessage(["session", "background", "text", "X", "--position", "middle"]) != nil)
    }

    @Test func sessionBackgroundRejectsOutOfRangeOpacity() {
        #expect(validationMessage(["session", "background", "image", "/tmp/bg.png", "--opacity", "1.5"]) != nil)
        #expect(validationMessage(["session", "background", "text", "X", "--opacity", "-0.2"]) != nil)
    }

    @Test func sessionBackgroundRejectsBadColor() {
        #expect(validationMessage(["session", "background", "text", "X", "--color", "red"]) != nil)
        #expect(validationMessage(["session", "background", "text", "X", "--color", "#fff"]) != nil)
    }

    @Test func sessionBackgroundAcceptsValidColor() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "active",
                                      args: ControlArgs(text: "X", mode: "text", color: "#ff8800"))
        #expect(try request(["session", "background", "text", "X", "--color", "#ff8800"]) == expected)
    }

    @Test func sessionBackgroundRejectsEmptyAndTooLongText() {
        #expect(validationMessage(["session", "background", "text", ""]) != nil)
        #expect(validationMessage(["session", "background", "text",
                                   String(repeating: "A", count: WatermarkConfig.maxTextLength + 1)]) != nil)
    }

    @Test func sessionBackgroundImageRejectsControlCharPath() {
        // the config-injection vector: a newline in the path would smuggle an extra ghostty key into the
        // per-surface overlay. Caught CLI-side (matching the server boundary) before any round-trip.
        #expect(validationMessage(["session", "background", "image", "x.png\nclipboard-read = allow\ny.png"]) != nil)
    }
}
