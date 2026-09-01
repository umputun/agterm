import ArgumentParser
import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

/// The requests the zmx group builds and the human output it renders. Nothing here talks to a socket:
/// the point is that the CLI cannot send a kill the server would have to refuse, and that a reader can
/// tell a closed window's resting state from a leak.
struct ZmxCommandsTests {
    @Test func treeCarriesItsHostAsAnArgumentNotATarget() throws {
        let tree = try Zmx.Tree.parse(["buildbox"])

        #expect(try tree.makeRequest().cmd == .zmxTree)
        #expect(try tree.makeRequest().args?.host == "buildbox")
        #expect(try tree.makeRequest().target == nil, "a remote host is not a local addressing target")
    }

    // no host is this app's own attachable sessions, which is the form the remote call runs on the far side
    @Test func treeWithoutAHostAsksAboutThisApp() throws {
        let tree = try Zmx.Tree.parse([])

        #expect(try tree.makeRequest().cmd == .zmxTree)
        #expect(try tree.makeRequest().args?.host == nil)
    }

    @Test func attachSendsTheHostAsAnArgumentAndTheSessionAsTheTarget() throws {
        let attach = try Zmx.Attach.parse(["buildbox", "s1"])

        #expect(try attach.makeRequest().cmd == .zmxAttach)
        #expect(try attach.makeRequest().args?.host == "buildbox")
        #expect(try attach.makeRequest().target == "s1")
    }

    @Test(arguments: [[], ["buildbox"]])
    func attachNeedsBothAHostAndASession(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try Zmx.Attach.parse(arguments) }
    }

    @Test func attachEchoesTheLocalSessionItCreated() throws {
        // it creates a session, so a script can pipe its id onward without --json
        #expect(try Zmx.Attach.parse(["buildbox", "s1"]).echoesResultID)
        #expect(try !Zmx.Tree.parse(["buildbox"]).echoesResultID, "a listing creates nothing to echo")
    }

    @Test func remoteTreeRendersOneRowPerAttachableSession() {
        let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx", socketDirectory: "/tmp/z")
        let plain = ControlRemoteSession(
            id: "s1", name: "build", windowID: "w-1", windowName: "main", workspaceID: "ws-1",
            workspaceName: "umputun.dev", cwd: "/repo", splitAxis: nil,
            panes: [ControlRemotePane(pane: "left", daemon: "agterm-1")])
        let split = ControlRemoteSession(
            id: "s2", name: "logs", windowID: "w-2", windowName: "second", workspaceID: "ws-2",
            workspaceName: "ops", context: "tailing prod", cwd: "/var", splitAxis: "horizontal",
            panes: [ControlRemotePane(pane: "left", daemon: "agterm-2", foreground: ["/usr/bin/tail", "-f"]),
                    ControlRemotePane(pane: "right", daemon: "agterm-3", foreground: ["/bin/zsh"])])
        let tree = ControlRemoteTree(host: "buildbox", endpoint: endpoint, sessions: [plain, split])

        let lines = SocketClient.formatRemoteTree(tree).split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines[0] == "  main/umputun.dev/build  [s1]  /repo", "no context and no command adds no tail")
        #expect(lines[1] == "  second/ops/logs (split horizontal)  [s2]  /var  tailing prod  tail | zsh")
    }

    // the bare form answers about this app, where no ssh destination exists to name
    @Test func aLocalEmptyListNamesNoHost() {
        let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx", socketDirectory: "/tmp/z")

        #expect(SocketClient.formatRemoteTree(ControlRemoteTree(host: nil, endpoint: endpoint, sessions: []))
                == "no attachable sessions")
    }

    @Test func anEmptyRemoteTreeSaysSoRatherThanPrintingNothing() {
        let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx", socketDirectory: "/tmp/z")
        let tree = ControlRemoteTree(host: "buildbox", endpoint: endpoint, sessions: [])

        #expect(SocketClient.formatRemoteTree(tree) == "no attachable sessions on buildbox",
                "silence reads the same as a failed read")
    }

    @Test func listAndPruneSendTheirCommandWithNothingToResolve() throws {
        let list = try Zmx.List.parse([])
        #expect(try list.makeRequest().cmd == .zmxList)
        #expect(try list.makeRequest().target == nil)

        let prune = try Zmx.Prune.parse([])
        #expect(try prune.makeRequest().cmd == .zmxPrune)
    }

    @Test(arguments: ["left", "primary", "top", "right", "split", "bottom"])
    func killAcceptsEveryPaneSpellingTheApiTakes(pane: String) throws {
        let kill = try Zmx.Kill.parse(["--target", "abc", "--pane", pane, "--force"])
        let request = try kill.makeRequest()
        #expect(request.cmd == .zmxKill)
        #expect(request.target == "abc")
        #expect(request.args?.pane == pane)
        #expect(request.args?.force == true)
    }

    @Test func killRefusesLocallyRatherThanSendingSomethingTheServerMustReject() throws {
        // parse runs validate, so a bad invocation never reaches the socket at all
        #expect(throws: (any Error).self) { try Zmx.Kill.parse(["--target", "abc", "--pane", "left"]) }
        #expect(throws: (any Error).self) {
            try Zmx.Kill.parse(["--target", "abc", "--pane", "scratch", "--force"])
        }
        // no --target at all: it must not default to the active session the way every other command does
        #expect(throws: (any Error).self) { try Zmx.Kill.parse(["--pane", "left", "--force"]) }
        #expect(throws: (any Error).self) {
            try Zmx.Kill.parse(["--target", "active", "--pane", "left", "--force"])
        }
        #expect(throws: (any Error).self) {
            try Zmx.Kill.parse(["--target", "abc", "--window", "active", "--pane", "left", "--force"])
        }
    }

    @Test func restoreModeReadsWithNoArgumentAndSetsWithOne() throws {
        #expect(try Restore.Mode.parse([]).makeRequest().args?.mode == nil)
        #expect(try Restore.Mode.parse(["live"]).makeRequest().args?.mode == "live")
        #expect(throws: (any Error).self) { try Restore.Mode.parse(["sideways"]) }
    }

    @Test func theHumanStatusSeparatesTheNextLaunchFromThisOne() {
        let needsRestart = ControlRestoreStatus(configured: .live, requestedAtLaunch: .rerun, active: .rerun,
                                                unavailableReason: nil)
        let rendered = SocketClient.formatRestoreStatus(needsRestart)

        #expect(rendered.contains("configured: live (next launch)"))
        #expect(rendered.contains("requested rerun, active rerun"))
        #expect(rendered.contains("restart agterm to apply the configured mode"))
    }

    @Test func aClosedWindowsPaneReadsAsClosedRatherThanAsALeak() throws {
        let pane = UUID()
        let claim = ZmxPaneClaim(paneIdentity: pane, pane: .left, pendingClose: false, windowID: UUID(),
                                 windowName: "work", windowState: .closed, workspaceID: UUID(),
                                 workspaceName: "workspace 1", sessionID: UUID(), sessionName: "build")
        let result = ZmxInventory.join(
            observed: [ZmxSessionRecord(name: ZmxSupport.daemonName(for: pane), clients: 0, leaderPID: 1)],
            claims: [claim], inventoryComplete: true)
        let status = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live,
                                          unavailableReason: nil)

        let rendered = SocketClient.formatZmx(ControlZmxInventory(restore: status, result: result))

        #expect(rendered.contains("claimed"))
        #expect(rendered.contains("0 clients"))
        // the count alone would read as an orphan; the window state is what says otherwise
        #expect(rendered.contains("[closed window]"))
        #expect(rendered.contains("running"), "observation stays its own column beside the count")
        #expect(rendered.contains("work / workspace 1 / build (left)"),
                "one session name can appear in two workspaces, so the path carries all three")
        // kill resolves by id, never by name, and a closed row may not appear in `tree` at all
        #expect(rendered.contains(String(claim.sessionID.uuidString.prefix(8))))
        #expect(rendered.contains("win \(claim.windowID.uuidString.prefix(8))"))
    }

    @Test func anIncompleteInventorySaysSoBeforeItsRows() {
        let status = ControlRestoreStatus(configured: .none, requestedAtLaunch: .none, active: .none,
                                          unavailableReason: nil)
        let result = ZmxInventory.join(observed: [], claims: [], inventoryComplete: false)

        let rendered = SocketClient.formatZmx(ControlZmxInventory(restore: status, result: result))
        #expect(rendered.contains("inventory incomplete"))
        #expect(rendered.contains("no daemons"))
    }
}
