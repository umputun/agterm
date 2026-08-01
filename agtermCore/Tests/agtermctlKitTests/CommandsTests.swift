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

    @Test func workspaceNewCollapsed() throws {
        let expected = ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "Work", collapsed: true))
        #expect(try request(["workspace", "new", "Work", "--collapsed"]) == expected)
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
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["workspace", "move"]) }
    }

    @Test func workspaceFocusDefaultsToggle() throws {
        #expect(try request(["workspace", "focus"]) == ControlRequest(cmd: .workspaceFocus, target: "active", args: ControlArgs(mode: "toggle")))
    }

    @Test func workspaceFocusOnWithTarget() throws {
        let expected = ControlRequest(cmd: .workspaceFocus, target: "9f3c", args: ControlArgs(mode: "on"))
        #expect(try request(["workspace", "focus", "on", "--target", "9f3c"]) == expected)
    }

    @Test func workspaceFocusAddWithTarget() throws {
        let expected = ControlRequest(cmd: .workspaceFocus, target: "9f3c", args: ControlArgs(mode: "add"))
        #expect(try request(["workspace", "focus", "add", "--target", "9f3c"]) == expected)
    }

    @Test func workspaceFocusRejectsBadMode() {
        // pin the exact allCases-derived message so an unrelated parse failure can't pass for it.
        #expect(validationMessage(["workspace", "focus", "sideways"]) == "mode must be one of: on, off, toggle, add")
    }

    @Test func workspaceFocusHelpListsEveryModeAndWhatItDoesToTheFilter() {
        // the abstract lists the raw values on its own, so asserting those alone would pass over a rotted
        // hand-written argument help — assert each mode's whole clause instead.
        let help = Workspace.Focus.helpMessage(columns: 400)
        for mode in ControlWorkspaceFocusMode.allCases {
            #expect(help.contains(mode.rawValue), "workspace focus help should list \(mode.rawValue), got: \(help)")
            #expect(help.contains(mode.helpSummary),
                    "workspace focus help should explain \(mode.rawValue)'s filter effect, got: \(help)")
        }
    }

    @Test func workspaceFilterDefaultsToggle() throws {
        #expect(try request(["workspace", "filter"]) == ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "toggle")))
    }

    @Test func workspaceFilterOn() throws {
        #expect(try request(["workspace", "filter", "on"]) == ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on")))
    }

    @Test func workspaceFilterOff() throws {
        #expect(try request(["workspace", "filter", "off"]) == ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "off")))
    }

    @Test func workspaceFilterThreadsWindow() throws {
        let expected = ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on", window: "win"))
        #expect(try request(["workspace", "filter", "on", "--window", "win"]) == expected)
    }

    @Test func workspaceFilterRejectsBadMode() {
        #expect(validationMessage(["workspace", "filter", "sideways"]) == "mode must be on, off, or toggle")
    }

    @Test func workspaceFilterTakesNoTarget() {
        // carrying only ClientOptions is what makes --target unknown here.
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["workspace", "filter", "on", "--target", "9f3c"]) }
    }

    @Test func workspaceCollapseDefaultsActive() throws {
        #expect(try request(["workspace", "collapse"]) == ControlRequest(cmd: .workspaceCollapse, target: "active"))
    }

    @Test func workspaceExpandWithTarget() throws {
        #expect(try request(["workspace", "expand", "--target", "9f3c"]) == ControlRequest(cmd: .workspaceExpand, target: "9f3c"))
    }

    @Test func workspaceCollapseThreadsWindow() throws {
        let expected = ControlRequest(cmd: .workspaceCollapse, target: "9f3c", args: ControlArgs(window: "win"))
        #expect(try request(["workspace", "collapse", "--target", "9f3c", "--window", "win"]) == expected)
    }

    @Test func workspaceExpandThreadsWindow() throws {
        let expected = ControlRequest(cmd: .workspaceExpand, target: "active", args: ControlArgs(window: "win"))
        #expect(try request(["workspace", "expand", "--window", "win"]) == expected)
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
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(workspaceName: "servers", createWorkspace: true))
        #expect(try request(["session", "new", "--workspace-name", "servers", "--create-workspace"]) == expected)
    }

    @Test func sessionNewWithNoSelect() throws {
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(noSelect: true))
        #expect(try request(["session", "new", "--no-select"]) == expected)
    }

    @Test func sessionNewWithCommandWait() throws {
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(command: "make test", wait: true))
        #expect(try request(["session", "new", "--command", "make test", "--wait"]) == expected)
    }

    @Test func sessionNewRejectsWaitWithoutCommand() {
        #expect(validationMessage(["session", "new", "--wait"]) == "--wait requires --command")
    }

    @Test func sessionNewRejectsWorkspaceAndWorkspaceName() {
        #expect(validationMessage(["session", "new", "--workspace", "active", "--workspace-name", "servers"])
            == "use either --workspace or --workspace-name, not both")
    }

    @Test func sessionNewRequiresWorkspaceNameForCreateWorkspace() {
        #expect(validationMessage(["session", "new", "--create-workspace"]) == "--create-workspace requires --workspace-name")
    }

    @Test func sessionNewAfter() throws {
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(after: "active"))
        #expect(try request(["session", "new", "--after", "active"]) == expected)
    }

    @Test func sessionNewBefore() throws {
        let expected = ControlRequest(cmd: .sessionNew, args: ControlArgs(before: "s1"))
        #expect(try request(["session", "new", "--before", "s1"]) == expected)
    }

    @Test func sessionNewRejectsAfterAndBefore() {
        #expect(validationMessage(["session", "new", "--after", "a", "--before", "b"])
            == "use either --after or --before, not both")
    }

    @Test func sessionNewRejectsAfterAndWorkspace() {
        #expect(validationMessage(["session", "new", "--after", "a", "--workspace", "ws1"])
            == "session.new takes --after/--before or a workspace, not both")
    }

    @Test func sessionNewRejectsBeforeAndWorkspaceName() {
        #expect(validationMessage(["session", "new", "--before", "a", "--workspace-name", "servers"])
            == "session.new takes --after/--before or a workspace, not both")
    }

    @Test func sessionDuplicateTargetsExplicitSession() throws {
        let expected = ControlRequest(cmd: .sessionDuplicate, target: "9f3c")
        #expect(try request(["session", "duplicate", "--target", "9f3c"]) == expected)
    }

    @Test func sessionDuplicateDefaultsToActive() throws {
        let expected = ControlRequest(cmd: .sessionDuplicate, target: "active")
        #expect(try request(["session", "duplicate"]) == expected)
    }

    @Test func sessionClose() throws {
        #expect(try request(["session", "close", "--target", "x"]) == ControlRequest(cmd: .sessionClose, target: "x"))
    }

    @Test func sessionCloseMultipleTargets() throws {
        let expected = ControlRequest(cmd: .sessionClose, target: "a", args: ControlArgs(targets: ["a", "b"]))
        #expect(try request(["session", "close", "--target", "a", "--target", "b"]) == expected)
    }

    @Test func sessionSelectDefaultsActive() throws {
        #expect(try request(["session", "select"]) == ControlRequest(cmd: .sessionSelect, target: "active"))
    }

    @Test func sessionSeenDefaultsActive() throws {
        #expect(try request(["session", "seen"]) == ControlRequest(cmd: .sessionSeen, target: "active"))
    }

    @Test func sessionSeenTargetAndWindow() throws {
        let expected = ControlRequest(cmd: .sessionSeen, target: "x", args: ControlArgs(window: "win"))
        #expect(try request(["session", "seen", "--target", "x", "--window", "win"]) == expected)
    }

    @Test func sessionRename() throws {
        let expected = ControlRequest(cmd: .sessionRename, target: "active", args: ControlArgs(name: "build"))
        #expect(try request(["session", "rename", "build"]) == expected)
    }

    @Test func sessionMove() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "s1", args: ControlArgs(workspace: "ws2"))
        #expect(try request(["session", "move", "ws2", "--target", "s1"]) == expected)
    }

    @Test func sessionMoveMultipleTargetsToWorkspace() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "s1",
                                      args: ControlArgs(targets: ["s1", "s2"], workspace: "ws2"))
        #expect(try request(["session", "move", "ws2", "--target", "s1", "--target", "s2"]) == expected)
    }

    @Test func sessionMoveReorder() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "active", args: ControlArgs(to: "up"))
        #expect(try request(["session", "move", "--to", "up"]) == expected)
    }

    @Test func sessionMoveRequiresWorkspaceOrTo() {
        #expect(validationMessage(["session", "move"]) == "provide a destination workspace, --to, or --after/--before")
    }

    @Test func sessionMoveRejectsWorkspaceAndTo() {
        #expect(validationMessage(["session", "move", "ws2", "--to", "up"]) == "provide a destination workspace or --to, not both")
    }

    @Test func sessionMoveRejectsMultipleTargetsWithReorder() {
        #expect(validationMessage(["session", "move", "--to", "up", "--target", "s1", "--target", "s2"])
            == "session.move --target can be repeated only with a workspace or --after/--before")
    }

    @Test func sessionMoveAfter() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "s1", args: ControlArgs(after: "s2"))
        #expect(try request(["session", "move", "--after", "s2", "--target", "s1"]) == expected)
    }

    @Test func sessionMoveAfterMultipleTargets() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "s1",
                                      args: ControlArgs(targets: ["s1", "s2"], after: "s3"))
        #expect(try request(["session", "move", "--after", "s3", "--target", "s1", "--target", "s2"]) == expected)
    }

    @Test func sessionMoveBefore() throws {
        let expected = ControlRequest(cmd: .sessionMove, target: "s1", args: ControlArgs(before: "s2"))
        #expect(try request(["session", "move", "--before", "s2", "--target", "s1"]) == expected)
    }

    @Test func sessionMoveRejectsAfterAndBefore() {
        #expect(validationMessage(["session", "move", "--after", "a", "--before", "b"])
            == "use either --after or --before, not both")
    }

    @Test func sessionMoveRejectsAfterAndTo() {
        #expect(validationMessage(["session", "move", "--after", "a", "--to", "up"])
            == "session.move takes --after/--before or --to, not both")
    }

    @Test func sessionMoveRejectsAfterAndWorkspace() {
        #expect(validationMessage(["session", "move", "ws2", "--after", "a"])
            == "session.move takes --after/--before or a workspace, not both")
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

    @Test func sessionTypeWithPane() throws {
        let expected = ControlRequest(cmd: .sessionType, target: "s1",
                                      args: ControlArgs(text: "ls\n", select: false, pane: "right"))
        #expect(try request(["session", "type", "ls\n", "--pane", "right", "--target", "s1"]) == expected)
    }

    @Test func sessionTypeWithoutPaneOmitsIt() throws {
        let req = try request(["session", "type", "ls\n"])
        #expect(req.args?.pane == nil)
    }

    @Test func sessionTypeWithPaneLeft() throws {
        // the server treats nil and "left" identically, but the CLI passes the value through rather than
        // dropping it.
        let req = try request(["session", "type", "ls\n", "--pane", "left"])
        #expect(req.args?.pane == "left")
    }

    @Test func sessionTypeWithPaneScratch() throws {
        let req = try request(["session", "type", "ls\n", "--pane", "scratch"])
        #expect(req.args?.pane == "scratch")
    }

    @Test func sessionTypeRejectsBadPane() {
        // `other` is a session.focus mode, not a typable pane.
        #expect(validationMessage(["session", "type", "x", "--pane", "other"]) == "--pane must be left, right, or scratch")
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
        #expect(validationMessage(["session", "resize"])?.contains("exactly one") == true)
        #expect(validationMessage(["session", "resize", "--split-ratio", "0.7", "--grow-left", "0.1"])?
            .contains("exactly one") == true)
    }

    @Test func sessionResizeRejectsNonFinite() {
        // nan/inf parse as Double but can't JSON-encode, so validate() rejects them.
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

    @Test func sessionPasteDefaultsActive() throws {
        #expect(try request(["session", "paste"]) == ControlRequest(cmd: .sessionPaste, target: "active"))
    }

    @Test func sessionPasteWithTarget() throws {
        #expect(try request(["session", "paste", "--target", "9f3c"]) == ControlRequest(cmd: .sessionPaste, target: "9f3c"))
    }

    @Test func sessionSelectAllDefaultsActive() throws {
        #expect(try request(["session", "select-all"]) == ControlRequest(cmd: .sessionSelectAll, target: "active"))
    }

    @Test func sessionSelectAllWithTarget() throws {
        #expect(try request(["session", "select-all", "--target", "9f3c"]) == ControlRequest(cmd: .sessionSelectAll, target: "9f3c"))
    }

    @Test func sessionTextDefaultsActive() throws {
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

    @Test func sessionTextWithPaneScratch() throws {
        let expected = ControlRequest(cmd: .sessionText, target: "active", args: ControlArgs(pane: "scratch"))
        #expect(try request(["session", "text", "--pane", "scratch"]) == expected)
    }

    @Test func sessionTextRejectsAllWithLines() {
        #expect(validationMessage(["session", "text", "--all", "--lines", "10"]) == "use either --all or --lines, not both")
    }

    @Test func sessionTextRejectsZeroLines() {
        // ArgumentParser intercepts a negative `-5` as a flag before validate() runs, so 0 is the only
        // CLI-reachable non-positive case.
        #expect(validationMessage(["session", "text", "--lines", "0"]) == "--lines must be greater than 0")
    }

    @Test func sessionTextRejectsBadPane() {
        #expect(validationMessage(["session", "text", "--pane", "other"]) == "--pane must be left, right, or scratch")
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

    @Test func sessionStatusWithColor() throws {
        let req = try request(["session", "status", "blocked", "--color", "#ff0000"])
        #expect(req.cmd == .sessionStatus)
        #expect(req.args?.status == "blocked")
        #expect(req.args?.color == "#ff0000")
        #expect(req == ControlRequest(cmd: .sessionStatus, target: "active",
                                      args: ControlArgs(status: "blocked", color: "#ff0000")))
    }

    @Test func sessionStatusWithoutColor() throws {
        let req = try request(["session", "status", "active"])
        #expect(req.args?.color == nil)
    }

    @Test func sessionStatusRejectsBadColor() {
        // pin the exact message so an unrelated parse failure can't masquerade as color validation.
        #expect(validationMessage(["session", "status", "blocked", "--color", "nope"]) == "color must be a #rrggbb hex value")
    }

    @Test func sessionStatusWithShape() throws {
        let req = try request(["session", "status", "blocked", "--shape", "triangle"])
        #expect(req.cmd == .sessionStatus)
        #expect(req.args?.status == "blocked")
        #expect(req.args?.shape == "triangle")
        #expect(req == ControlRequest(cmd: .sessionStatus, target: "active",
                                      args: ControlArgs(status: "blocked", shape: "triangle")))
    }

    @Test(arguments: StatusShape.allCases)
    func sessionStatusAcceptsEveryShape(_ shape: StatusShape) throws {
        #expect(try request(["session", "status", "active", "--shape", shape.rawValue]).args?.shape == shape.rawValue)
    }

    @Test func sessionStatusWithoutShape() throws {
        let req = try request(["session", "status", "active"])
        #expect(req.args?.shape == nil)
    }

    @Test func sessionStatusRejectsUnknownShape() {
        // pin the exact allCases-derived message so an unrelated parse failure can't pass for it.
        #expect(validationMessage(["session", "status", "blocked", "--shape", "hexagon"])
            == "shape must be one of: circle, square, triangle, diamond, capsule, star")
    }

    @Test func sessionStatusShapeHelpListsEveryShape() {
        // the help is built from allCases, so a shape added later cannot leave `--help` stale.
        let help = Session.Status.helpMessage(columns: 200)
        for shape in StatusShape.allCases {
            #expect(help.contains(shape.rawValue), "--shape help should list \(shape.rawValue), got: \(help)")
        }
    }

    @Test func sessionStatusWithPane() throws {
        let expected = ControlRequest(cmd: .sessionStatus, target: "s1",
                                      args: ControlArgs(pane: "right", status: "blocked"))
        #expect(try request(["session", "status", "blocked", "--pane", "right", "--target", "s1"]) == expected)
    }

    @Test func sessionStatusWithPaneScratch() throws {
        let req = try request(["session", "status", "blocked", "--pane", "scratch"])
        #expect(req.args?.pane == "scratch")
    }

    @Test func sessionStatusWithoutPaneOmitsIt() throws {
        let req = try request(["session", "status", "blocked"])
        #expect(req.args?.pane == nil)
    }

    @Test func sessionStatusWithPaneID() throws {
        let expected = ControlRequest(cmd: .sessionStatus, target: "s1",
                                      args: ControlArgs(pane: "right", paneID: "agent-tok", status: "blocked"))
        #expect(try request(["session", "status", "blocked", "--pane", "right",
                             "--pane-id", "agent-tok", "--target", "s1"]) == expected)
    }

    @Test func sessionStatusWithoutPaneIDOmitsIt() throws {
        let req = try request(["session", "status", "blocked"])
        #expect(req.args?.paneID == nil)
    }

    @Test func sessionStatusRejectsBadPane() {
        #expect(validationMessage(["session", "status", "blocked", "--pane", "other"]) == "--pane must be left, right, or scratch")
    }

    @Test func sessionRestorePinsCommand() throws {
        let expected = ControlRequest(cmd: .sessionRestore, target: "s1",
                                      args: ControlArgs(mode: "set", command: "claude --resume abc"))
        #expect(try request(["session", "restore", "claude --resume abc", "--target", "s1"]) == expected)
    }

    @Test func sessionRestoreCarriesShellLineVerbatim() throws {
        let line = "cd /tmp && claude --resume abc | tee out"
        let req = try request(["session", "restore", line])
        #expect(req.args?.command == line)
    }

    @Test func sessionRestoreNone() throws {
        let expected = ControlRequest(cmd: .sessionRestore, target: "active", args: ControlArgs(mode: "none"))
        let req = try request(["session", "restore", "--none"])
        #expect(req == expected)
        #expect(req.args?.command == nil)
    }

    @Test func sessionRestoreClear() throws {
        let expected = ControlRequest(cmd: .sessionRestore, target: "active", args: ControlArgs(mode: "clear"))
        let req = try request(["session", "restore", "--clear"])
        #expect(req == expected)
        #expect(req.args?.command == nil)
    }

    @Test func sessionRestoreWithPaneAndPaneID() throws {
        let expected = ControlRequest(cmd: .sessionRestore, target: "s1",
                                      args: ControlArgs(mode: "set", command: "claude -c",
                                                        pane: "right", paneID: "pane-tok"))
        #expect(try request(["session", "restore", "claude -c", "--pane", "right",
                             "--pane-id", "pane-tok", "--target", "s1"]) == expected)
    }

    @Test func sessionRestoreWithoutPaneOmitsBoth() throws {
        let req = try request(["session", "restore", "--clear"])
        #expect(req.args?.pane == nil)
        #expect(req.args?.paneID == nil)
    }

    @Test func sessionRestoreCarriesWindow() throws {
        let expected = ControlRequest(cmd: .sessionRestore, target: "active",
                                      args: ControlArgs(mode: "none", window: "w1"))
        #expect(try request(["session", "restore", "--none", "--window", "w1"]) == expected)
    }

    @Test func sessionRestoreRequiresOneForm() {
        #expect(validationMessage(["session", "restore"]) == "provide exactly one of a COMMAND, --none, or --clear")
    }

    @Test func sessionRestoreRejectsCommandWithNone() {
        #expect(validationMessage(["session", "restore", "claude", "--none"])
            == "provide exactly one of a COMMAND, --none, or --clear")
    }

    @Test func sessionRestoreRejectsNoneWithClear() {
        #expect(validationMessage(["session", "restore", "--none", "--clear"])
            == "provide exactly one of a COMMAND, --none, or --clear")
    }

    @Test func sessionRestoreRejectsBadPane() {
        #expect(validationMessage(["session", "restore", "--clear", "--pane", "other"]) == "--pane must be left, right, or scratch")
    }

    @Test func sessionSearchWithNeedle() throws {
        let expected = ControlRequest(cmd: .sessionSearch, target: "active", args: ControlArgs(text: "error"))
        #expect(try request(["session", "search", "error"]) == expected)
    }

    @Test func sessionSearchOpensWithoutNeedleOrFlag() throws {
        // the command always passes a base ControlArgs to withWindow, so the bag is empty rather than nil.
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
        #expect(validationMessage(["session", "search"] + flags) == "--next, --prev, and --close are mutually exclusive")
    }

    @Test func sessionSearchRejectsNeedleWithClose() {
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

    @Test func sessionOverlayOpenWithBackgroundColor() throws {
        // --background-color maps to ControlArgs.color (shared field, disambiguated by the command).
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active",
                                      args: ControlArgs(command: "revdiff", color: "#2a1a3a"))
        #expect(try request(["session", "overlay", "open", "revdiff", "--background-color", "#2a1a3a"]) == expected)
    }

    @Test func sessionOverlayOpenRejectsBadBackgroundColor() {
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["session", "overlay", "open", "cmd", "--background-color", "purple"])
        }
    }

    @Test func sessionOverlayOpenWithFollow() throws {
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active",
                                      args: ControlArgs(command: "revdiff", follow: true))
        #expect(try request(["session", "overlay", "open", "revdiff", "--follow"]) == expected)
    }

    @Test func sessionOverlayOpenWithoutFollow() throws {
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active", args: ControlArgs(command: "revdiff"))
        let built = try request(["session", "overlay", "open", "revdiff"])
        #expect(built == expected)
        #expect(built.args?.follow == nil)
    }

    @Test func sessionOverlayOpenFollowWithBlockAndSizePercentAndTarget() throws {
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c",
                                      args: ControlArgs(command: "htop", sizePercent: 60, follow: true))
        #expect(try request(["session", "overlay", "open", "htop", "--follow", "--block",
                             "--size-percent", "60", "--target", "9f3c"]) == expected)
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
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active",
                                      args: ControlArgs(command: "htop", sizePercent: 60))
        #expect(try request(["session", "overlay", "open", "htop", "--block", "--size-percent", "60"]) == expected)
    }

    @Test func sessionOverlayResult() throws {
        #expect(try request(["session", "overlay", "result", "--target", "9f3c"])
            == ControlRequest(cmd: .sessionOverlayResult, target: "9f3c"))
    }

    @Test func sessionOverlayResizeWithSizePercent() throws {
        let expected = ControlRequest(cmd: .sessionOverlayResize, target: "9f3c", args: ControlArgs(sizePercent: 40))
        #expect(try request(["session", "overlay", "resize", "--size-percent", "40", "--target", "9f3c"]) == expected)
    }

    @Test func sessionOverlayResizeFull() throws {
        let expected = ControlRequest(cmd: .sessionOverlayResize, target: "active", args: ControlArgs(full: true))
        #expect(try request(["session", "overlay", "resize", "--full"]) == expected)
    }

    @Test func sessionOverlayResizeRejectsBadArgs() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "overlay", "resize"]) }
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["session", "overlay", "resize", "--full", "--size-percent", "50"])
        }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "overlay", "resize", "--size-percent", "150"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["session", "overlay", "resize", "--size-percent", "0"]) }
    }

    @Test func sessionOverlayBlockRejectsWait() {
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["session", "overlay", "open", "cmd", "--block", "--wait"])
        }
    }

    @Test func sessionOverlayOpenWithPane() throws {
        let left = ControlRequest(cmd: .sessionOverlayOpen, target: "active",
                                  args: ControlArgs(command: "revdiff", pane: "left"))
        #expect(try request(["session", "overlay", "open", "revdiff", "--pane", "left"]) == left)
        let right = ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c",
                                   args: ControlArgs(command: "htop", pane: "right"))
        #expect(try request(["session", "overlay", "open", "htop", "--pane", "right", "--target", "9f3c"]) == right)
    }

    @Test func sessionOverlayOpenPaneWithTheOtherFlags() throws {
        let expected = ControlRequest(cmd: .sessionOverlayOpen, target: "active",
                                      args: ControlArgs(cwd: "/b", command: "revdiff", wait: true, follow: true,
                                                        pane: "right", color: "#2a1a3a"))
        #expect(try request(["session", "overlay", "open", "revdiff", "--pane", "right", "--cwd", "/b",
                             "--wait", "--follow", "--background-color", "#2a1a3a"]) == expected)
    }

    @Test func sessionOverlayOpenWithoutPane() throws {
        #expect(try request(["session", "overlay", "open", "revdiff"]).args?.pane == nil)
    }

    @Test func sessionOverlayPaneRejectsScratch() {
        #expect(validationMessage(["session", "overlay", "open", "cmd", "--pane", "scratch"])
            == "--pane must be left or right")
        #expect(validationMessage(["session", "overlay", "close", "--pane", "scratch"]) == "--pane must be left or right")
        #expect(validationMessage(["session", "overlay", "result", "--pane", "scratch"]) == "--pane must be left or right")
        #expect(validationMessage(["session", "overlay", "open", "cmd", "--pane", "middle"]) == "--pane must be left or right")
    }

    @Test func sessionOverlayOpenRejectsPaneWithSizePercent() {
        #expect(validationMessage(["session", "overlay", "open", "cmd", "--pane", "left", "--size-percent", "70"])
            == "--pane cannot be combined with --size-percent (pane overlays are always full)")
    }

    @Test func sessionOverlayCloseWithPane() throws {
        let expected = ControlRequest(cmd: .sessionOverlayClose, target: "active", args: ControlArgs(pane: "left"))
        #expect(try request(["session", "overlay", "close", "--pane", "left"]) == expected)
        #expect(try request(["session", "overlay", "close"]).args == nil)
    }

    @Test func sessionOverlayResultWithPane() throws {
        let expected = ControlRequest(cmd: .sessionOverlayResult, target: "9f3c", args: ControlArgs(pane: "right"))
        #expect(try request(["session", "overlay", "result", "--pane", "right", "--target", "9f3c"]) == expected)
        #expect(try request(["session", "overlay", "result"]).args == nil)
    }

    @Test func sessionOverlayResizeHasNoPaneOption() {
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["session", "overlay", "resize", "--full", "--pane", "left"])
        }
    }

    @Test func sessionOverlayBlockPollCarriesPane() throws {
        let parsed = try Agtermctl.parseAsRoot(["session", "overlay", "open", "revdiff", "--block", "--pane", "right"])
        let open = try #require(parsed as? agtermctlKit.Session.Overlay.Open)
        #expect(open.resultRequest(id: "9f3c")
            == ControlRequest(cmd: .sessionOverlayResult, target: "9f3c", args: ControlArgs(pane: "right")))
    }

    @Test func sessionOverlayBlockPollWithoutPane() throws {
        let parsed = try Agtermctl.parseAsRoot(["session", "overlay", "open", "revdiff", "--block"])
        let open = try #require(parsed as? agtermctlKit.Session.Overlay.Open)
        #expect(open.resultRequest(id: "9f3c") == ControlRequest(cmd: .sessionOverlayResult, target: "9f3c"))
    }

    @Test func sessionOverlayPaneBlockStillRejectsWait() {
        #expect(validationMessage(["session", "overlay", "open", "cmd", "--pane", "left", "--block", "--wait"])
            == "--block cannot be combined with --wait")
    }

    @Test func quickDefaultsToggle() throws {
        #expect(try request(["quick"]) == ControlRequest(cmd: .quick, args: ControlArgs(mode: "toggle")))
    }

    @Test func quickShow() throws {
        #expect(try request(["quick", "show"]) == ControlRequest(cmd: .quick, args: ControlArgs(mode: "show")))
    }

    @Test func quickTypeWithText() throws {
        #expect(try request(["quick", "type", "ls\n"]) == ControlRequest(cmd: .quickType, args: ControlArgs(text: "ls\n")))
    }

    @Test func quickTypeStdinFlagParses() throws {
        // the --stdin flag parses (we don't call makeRequest here — it would block reading stdin).
        let command = try Quick.TypeText.parse(["--stdin"])
        #expect(command.stdin)
        #expect(command.text == nil)
    }

    @Test func quickTypeWithoutTextOrStdinThrows() {
        // the message is raised in makeRequest, not validate, so parseAsRoot alone would not reach it.
        #expect(throws: (any Error).self) { try request(["quick", "type"]) }
    }

    @Test func quickTextDefaultsToVisibleScreen() throws {
        #expect(try request(["quick", "text"]) == ControlRequest(cmd: .quickText, args: ControlArgs()))
    }

    @Test func quickTextWithAll() throws {
        #expect(try request(["quick", "text", "--all"]) == ControlRequest(cmd: .quickText, args: ControlArgs(all: true)))
    }

    @Test func quickTextWithLines() throws {
        #expect(try request(["quick", "text", "--lines", "50"]) == ControlRequest(cmd: .quickText, args: ControlArgs(lines: 50)))
    }

    @Test func quickTextRejectsAllWithLines() {
        #expect(validationMessage(["quick", "text", "--all", "--lines", "10"]) == "use either --all or --lines, not both")
    }

    @Test func quickTextRejectsZeroLines() {
        #expect(validationMessage(["quick", "text", "--lines", "0"]) == "--lines must be greater than 0")
    }

    @Test func surfaceZoomDefaultsToggleActive() throws {
        #expect(try request(["surface", "zoom"]) ==
            ControlRequest(cmd: .surfaceZoom, target: "active", args: ControlArgs(mode: "toggle")))
    }

    @Test func surfaceZoomTargetsSurfaceID() throws {
        let id = "surface:5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9:right"

        #expect(try request(["surface", "zoom", "show", "--target", id]) ==
            ControlRequest(cmd: .surfaceZoom, target: id, args: ControlArgs(mode: "show")))
    }

    @Test func surfaceZoomTargetsWindow() throws {
        #expect(try request(["surface", "zoom", "hide", "--window", "win"]) ==
            ControlRequest(cmd: .surfaceZoom, target: "active", args: ControlArgs(mode: "hide", window: "win")))
    }

    // MARK: - pick

    @Test func pickDefaultsToOpen() throws {
        #expect(try Agtermctl.parseAsRoot(["pick"]) is Pick.Open)
    }

    @Test func pickOpenSniffsJSONArray() throws {
        let input = Data("""
          [
            {"id":"one","label":"One","subtitle":"First"},
            {"id":"two","label":"Two"}
          ]
        """.utf8)

        #expect(try Pick.Open.parseItems(input) == [
            ControlPickItem(id: "one", label: "One", subtitle: "First"),
            ControlPickItem(id: "two", label: "Two")
        ])
    }

    @Test func pickOpenSniffsBareLines() throws {
        #expect(try Pick.Open.parseItems(Data("One\nTwo\n".utf8)) == [
            ControlPickItem(id: "One", label: "One"),
            ControlPickItem(id: "Two", label: "Two")
        ])
    }

    @Test func pickOpenDropsBlankLines() throws {
        #expect(try Pick.Open.parseItems(Data("\nOne\n \t \n\nTwo\n".utf8)) == [
            ControlPickItem(id: "One", label: "One"),
            ControlPickItem(id: "Two", label: "Two")
        ])
    }

    @Test func pickOpenAcceptsEmptyStdinAsNoItems() throws {
        #expect(try Pick.Open.parseItems(Data()).isEmpty)
    }

    @Test func pickOpenRejectsMalformedJSON() {
        #expect(throws: (any Error).self) {
            try Pick.Open.parseItems(Data("[{\"id\":\"one\"".utf8))
        }
    }

    @Test func pickOpenMapsEveryOptionToRequest() throws {
        let command = try Pick.Open.parse([
            "--prompt", "Choose one", "--query", "on", "--allow-custom", "--follow",
            "--window", "w1", "--no-block"
        ])
        let items = [ControlPickItem(id: "One", label: "One")]
        let expected = ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(
                follow: true, items: items, prompt: "Choose one", query: "on",
                allowCustom: true, window: "w1"
            )
        )

        #expect(try command.makeRequest(input: Data("One\n".utf8)) == expected)
        #expect(command.noBlock)
    }

    @Test func pickOpenDefaultsToBlockingWithoutOptionalArgs() throws {
        let command = try Pick.Open.parse([])
        let items = [ControlPickItem(id: "One", label: "One")]

        #expect(try command.makeRequest(input: Data("One\n".utf8)) ==
            ControlRequest(cmd: .pickOpen, args: ControlArgs(items: items)))
        #expect(!command.noBlock)
    }

    @Test func pickOpenComposesTheItemlessRenameRequest() throws {
        let command = try Pick.Open.parse(["--allow-custom", "--query", "old name"])

        #expect(try command.makeRequest(input: Data()) == ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: [], query: "old name", allowCustom: true)
        ))
    }

    @Test func pickResultMapsIDAndWindow() throws {
        #expect(try request(["pick", "result", "pick-1", "--window", "w1"]) ==
            ControlRequest(cmd: .pickResult, target: "pick-1", args: ControlArgs(window: "w1")))
    }

    @Test func pickCancelMapsIDAndWindow() throws {
        #expect(try request(["pick", "cancel", "pick-1", "--window", "w1"]) ==
            ControlRequest(cmd: .pickCancel, target: "pick-1", args: ControlArgs(window: "w1")))
    }

    @Test func pickOpenHasNoTimeoutOption() {
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["pick", "--timeout", "60"])
        }
    }

    // MARK: - dashboard

    @Test func dashboardOpenWithIdsAndFontSize() throws {
        let expected = ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["s1", "s2"], fontSize: 12))
        #expect(try request(["dashboard", "s1", "s2", "--font-size", "12"]) == expected)
    }

    @Test func dashboardOpenWithAutoSize() throws {
        let expected = ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["s1", "s2"], autoSize: true))
        #expect(try request(["dashboard", "s1", "s2", "--auto-size"]) == expected)
    }

    @Test func dashboardOpenTargetsWindow() throws {
        let expected = ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["s1"], window: "win"))
        #expect(try request(["dashboard", "s1", "--window", "win"]) == expected)
    }

    @Test func dashboardClose() throws {
        #expect(try request(["dashboard", "--close"]) == ControlRequest(cmd: .dashboard, args: ControlArgs(close: true)))
    }

    @Test func dashboardForwardsPaneRefsVerbatim() throws {
        let expected = ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["s1:left", "s2:right", "s3"]))
        #expect(try request(["dashboard", "s1:left", "s2:right", "s3"]) == expected)
    }

    @Test func dashboardForwardsAPaneRefOnActive() throws {
        let expected = ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["active:left"]))
        #expect(try request(["dashboard", "active:left"]) == expected)
    }

    // grammar is the dispatcher's call, not the CLI's — a bad suffix must still reach the socket
    @Test func dashboardDoesNotValidatePaneGrammarLocally() throws {
        let expected = ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["s1:nope"]))
        #expect(try request(["dashboard", "s1:nope"]) == expected)
    }

    @Test func dashboardRejectsMruWithPaneRefs() {
        #expect(validationMessage(["dashboard", "s1:left", "--mru"]) == "--mru cannot be combined with session ids")
    }

    @Test func dashboardRejectsFontSizeWithAutoSize() {
        #expect(validationMessage(["dashboard", "s1", "--font-size", "12", "--auto-size"])
            == "--font-size is mutually exclusive with --auto-size")
    }

    @Test func dashboardRejectsNonPositiveFontSize() {
        #expect(validationMessage(["dashboard", "s1", "--font-size", "0"]) == "--font-size must be a positive number")
    }

    @Test func dashboardRejectsCloseWithIds() {
        #expect(validationMessage(["dashboard", "s1", "--close"]) == "--close takes no ids, --mru, or font options")
    }

    @Test func dashboardRejectsCloseWithAutoSize() {
        #expect(validationMessage(["dashboard", "--close", "--auto-size"]) == "--close takes no ids, --mru, or font options")
    }

    @Test func dashboardRejectsEmptyIdsWithoutClose() {
        #expect(validationMessage(["dashboard"]) == "dashboard requires at least one session id (or --mru, or --close)")
    }

    @Test func dashboardMruAlone() throws {
        #expect(try request(["dashboard", "--mru"]) == ControlRequest(cmd: .dashboard, args: ControlArgs(mru: true)))
    }

    @Test func dashboardMruWithAutoSizeAndWindow() throws {
        let expected = ControlRequest(cmd: .dashboard, args: ControlArgs(window: "win", autoSize: true, mru: true))
        #expect(try request(["dashboard", "--mru", "--auto-size", "--window", "win"]) == expected)
    }

    @Test func dashboardRejectsMruWithIds() {
        #expect(validationMessage(["dashboard", "s1", "--mru"]) == "--mru cannot be combined with session ids")
    }

    @Test func dashboardRejectsMruWithClose() {
        #expect(validationMessage(["dashboard", "--mru", "--close"]) == "--close takes no ids, --mru, or font options")
    }

    @Test func dashboardRejectsNegativeFontSize() {
        #expect(validationMessage(["dashboard", "s1", "--font-size=-3"]) == "--font-size must be a positive number")
    }

    @Test func dashboardRejectsInfiniteFontSize() {
        #expect(validationMessage(["dashboard", "s1", "--font-size=inf"]) == "--font-size must be a positive number")
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

    @Test func fontIncWithPane() throws {
        #expect(try request(["font", "inc", "--pane", "right", "--target", "s1"])
            == ControlRequest(cmd: .fontInc, target: "s1", args: ControlArgs(pane: "right")))
    }

    @Test func fontDecWithPaneScratch() throws {
        #expect(try request(["font", "dec", "--pane", "scratch"])
            == ControlRequest(cmd: .fontDec, target: "active", args: ControlArgs(pane: "scratch")))
    }

    @Test func fontResetWithPaneAndWindow() throws {
        #expect(try request(["font", "reset", "--pane", "left", "--window", "w1"])
            == ControlRequest(cmd: .fontReset, target: "active", args: ControlArgs(window: "w1", pane: "left")))
    }

    @Test func fontRejectsInvalidPane() throws {
        #expect(validationMessage(["font", "inc", "--pane", "other"]) == "--pane must be left, right, or scratch")
    }

    @Test func keymapReload() throws {
        #expect(try request(["keymap", "reload"]) == ControlRequest(cmd: .keymapReload))
    }

    @Test func keymapReloadRejectsWindowSelector() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["keymap", "reload", "--window", "w1"]) }
    }

    @Test func keymapList() throws {
        #expect(try request(["keymap", "list"]) == ControlRequest(cmd: .keymapList))
    }

    @Test func keymapListRejectsWindowSelector() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["keymap", "list", "--window", "w1"]) }
    }

    @Test func configReload() throws {
        #expect(try request(["config", "reload"]) == ControlRequest(cmd: .configReload))
    }

    @Test func configReloadRejectsWindowSelector() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["config", "reload", "--window", "w1"]) }
    }

    // MARK: - theme subcommands

    @Test func themeSetWithName() throws {
        #expect(try request(["theme", "set", "Dracula"]) == ControlRequest(cmd: .themeSet, args: ControlArgs(name: "Dracula")))
    }

    @Test func themeSetWithoutNameSelectsDefault() throws {
        #expect(try request(["theme", "set"]) == ControlRequest(cmd: .themeSet, args: ControlArgs(name: nil)))
    }

    @Test func themeSetSyncWithBothSides() throws {
        #expect(try request(["theme", "set", "--light", "Builtin Light", "--dark", "agterm"])
            == ControlRequest(cmd: .themeSet, args: ControlArgs(light: "Builtin Light", dark: "agterm")))
    }

    @Test func themeSetOneSlotAlone() throws {
        #expect(try request(["theme", "set", "--light", "Builtin Light"])
            == ControlRequest(cmd: .themeSet, args: ControlArgs(light: "Builtin Light")))
        #expect(try request(["theme", "set", "--dark", "Nord"])
            == ControlRequest(cmd: .themeSet, args: ControlArgs(dark: "Nord")))
        // the reserved 'none' keyword (clear the dark slot) travels as a plain value.
        #expect(try request(["theme", "set", "--dark", "none"])
            == ControlRequest(cmd: .themeSet, args: ControlArgs(dark: "none")))
    }

    @Test func themeSetRejectsNamePlusLight() {
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["theme", "set", "Dracula", "--light", "Builtin Light"])
        }
    }

    @Test func themeList() throws {
        #expect(try request(["theme", "list"]) == ControlRequest(cmd: .themeList))
    }

    @Test func themeRejectsWindowSelector() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["theme", "set", "Nord", "--window", "w1"]) }
    }

    // MARK: - window subcommands

    @Test func windowNewWithName() throws {
        #expect(try request(["window", "new", "Work"]) == ControlRequest(cmd: .windowNew, args: ControlArgs(name: "Work")))
    }

    @Test func windowNewWithoutName() throws {
        #expect(try request(["window", "new"]) == ControlRequest(cmd: .windowNew, args: ControlArgs(name: nil)))
    }

    @Test func windowNewMinimized() throws {
        #expect(try request(["window", "new", "Work", "--minimized"])
            == ControlRequest(cmd: .windowNew, args: ControlArgs(name: "Work", minimized: true)))
        // omitted rather than false, so an un-flagged create stays byte-identical on the wire
        #expect(try request(["window", "new", "Work"])
            == ControlRequest(cmd: .windowNew, args: ControlArgs(name: "Work", minimized: nil)))
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

    @Test func windowZoom() throws {
        #expect(try request(["window", "zoom", "9f3c"]) == ControlRequest(cmd: .windowZoom, target: "9f3c"))
    }

    @Test func windowFullscreen() throws {
        #expect(try request(["window", "fullscreen", "9f3c"]) == ControlRequest(cmd: .windowFullscreen, target: "9f3c"))
    }

    @Test func windowFullscreenDefaultsActive() throws {
        #expect(try request(["window", "fullscreen"]) == ControlRequest(cmd: .windowFullscreen, target: "active"))
    }

    @Test func windowMinimize() throws {
        #expect(try request(["window", "minimize", "9f3c", "on"])
            == ControlRequest(cmd: .windowMinimize, target: "9f3c", args: ControlArgs(mode: "on")))
        #expect(try request(["window", "minimize", "9f3c", "off"])
            == ControlRequest(cmd: .windowMinimize, target: "9f3c", args: ControlArgs(mode: "off")))
    }

    @Test func windowMinimizeDefaultsActiveAndToggle() throws {
        #expect(try request(["window", "minimize"])
            == ControlRequest(cmd: .windowMinimize, target: "active", args: ControlArgs(mode: "toggle")))
    }

    @Test func windowMinimizeBareModeTargetsActive() throws {
        // both positionals are optional, so a bare mode word would otherwise bind to the id; a window
        // address is a hex prefix or `active`, never a mode word, so the recovery can't misfire.
        #expect(try request(["window", "minimize", "on"])
            == ControlRequest(cmd: .windowMinimize, target: "active", args: ControlArgs(mode: "on")))
        #expect(try request(["window", "minimize", "toggle"])
            == ControlRequest(cmd: .windowMinimize, target: "active", args: ControlArgs(mode: "toggle")))
        // an id that merely looks like a mode word is still an id (hex `0ff`, not the word `off`)
        #expect(try request(["window", "minimize", "0ff"])
            == ControlRequest(cmd: .windowMinimize, target: "0ff", args: ControlArgs(mode: "toggle")))
    }

    @Test func windowDeleteDefaultsActive() throws {
        #expect(try request(["window", "delete"]) == ControlRequest(cmd: .windowDelete, target: "active"))
    }

    @Test func windowRenameRequiresBothArgsFails() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "rename", "9f3c"]) }
    }

    @Test func windowCommandsRejectWindowSelector() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "list", "--window", "w1"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "select", "9f3c", "--window", "w1"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["quick", "--window", "w1"]) }
    }

    @Test func windowCommandsKeepSocketAndJSON() throws {
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
        #expect(try request(["tree"]) == ControlRequest(cmd: .tree))
    }

    // --window folds into the command's existing args bag rather than replacing it.

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

    @Test func sessionRevealWithWindow() throws {
        let expected = ControlRequest(cmd: .sessionReveal, target: "s1", args: ControlArgs(window: "w1"))
        #expect(try request(["session", "reveal", "--target", "s1", "--window", "w1"]) == expected)
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
        // a newline in the path would smuggle an extra ghostty key into the per-surface overlay.
        #expect(validationMessage(["session", "background", "image", "x.png\nclipboard-read = allow\ny.png"]) != nil)
    }
}
