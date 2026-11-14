import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsSessionsTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession(command: String? = nil, cwd: String? = nil) -> ControlResponse {
        harness.actions.createSession(ControlSessionCreateOptions(window: nil, cwd: cwd, workspace: nil, workspaceName: nil,
                                                                  createWorkspace: nil, command: command, wait: nil, name: nil,
                                                                  after: nil, before: nil, noSelect: false))
    }

    @Test func aNewSessionStartsItsPaneDaemonWithThePaneEnvironment() throws {
        let reply = newSession(cwd: harness.scratch.root)
        let session = try harness.session(reply)

        let launch = try #require(harness.runner.launches.first)
        #expect(launch.name == ZmxSupport.daemonName(for: session.paneIdentity))
        #expect(launch.argv.isEmpty)
        #expect(launch.directory == harness.scratch.root)
        #expect(launch.environment["AGTERM_SESSION_ID"] == session.id.uuidString)
        #expect(launch.environment["AGTERM_PANE"] == "left")
        #expect(launch.environment["AGTERM_PANE_ID"] == session.paneIdentity.uuidString)
        #expect(launch.environment["AGTERM_WINDOW_ID"] == harness.catalog.id.uuidString)
        #expect(launch.environment["AGTERM_STATE_DIR"] == harness.scratch.state)
        #expect(launch.environment["AGTERM_SOCKET"] == harness.scratch.state + "/agterm.sock")
        #expect(launch.environment["ZMX_DIR"]?.hasPrefix(harness.scratch.runtime + "/agterm-zmx-") == true)
        #expect(launch.environment["ZMX_EXIT_FILE"] == harness.panes.exitRecord(session.paneIdentity))
        #expect(launch.environment["TERM"] == "xterm-ghostty")
        #expect(launch.environment["SHELL"] == "/bin/zsh")
        #expect(session.daemonBackedPanes == [session.paneIdentity])
        #expect(harness.store.selectedSessionID != session.id)
    }

    @Test func aSessionCommandRunsThroughTheLoginShellAndEndsThePane() throws {
        _ = newSession(command: "htop")

        let launch = try #require(harness.runner.launches.first)
        #expect(launch.argv == ["/bin/zsh", "-lic", ZmxReplayScript.renderEnding(commandLine: "htop")])
    }

    @Test func aDaemonThatCannotStartLeavesNoSession() {
        harness.runner.failure = "zmx: boom"
        let before = harness.store.workspaces.flatMap(\.sessions).count

        let reply = newSession()

        #expect(reply == ControlResponse(ok: false, error: "could not start the pane: zmx: boom"))
        #expect(harness.store.workspaces.flatMap(\.sessions).count == before)
    }

    @Test func anUnsupportedLoginShellIsRefused() throws {
        let harness = try ServerHarness(shell: "/bin/tcsh")

        let reply = harness.actions.createSession(ControlSessionCreateOptions(window: nil, cwd: nil, workspace: nil,
                                                                              workspaceName: nil, createWorkspace: nil, command: nil,
                                                                              wait: nil, name: nil, after: nil, before: nil,
                                                                              noSelect: false))

        #expect(reply == ControlResponse(ok: false, error: ServerShell.refusal("/bin/tcsh")))
        #expect(harness.runner.launches.isEmpty)
    }

    @Test func waitHoldsThePaneAfterItsCommand() throws {
        let reply = harness.actions.createSession(ControlSessionCreateOptions(window: nil, cwd: nil, workspace: nil,
                                                                              workspaceName: nil, createWorkspace: nil,
                                                                              command: "make", wait: true, name: nil, after: nil,
                                                                              before: nil, noSelect: false))

        let session = try harness.session(reply)
        #expect(session.commandWait)
        #expect(harness.runner.launches.last?.argv == ["/bin/zsh", "-lic", ZmxReplayScript.renderHolding(commandLine: "make")])
    }

    @Test func aCompanionWithWaitHoldsItsPaneToo() async throws {
        let parent = try harness.session(newSession())

        let reply = await harness.actions.createCompanion(parent.id.uuidString, options: CompanionOptions(command: "top", wait: true),
                                                          window: nil)

        #expect(reply.ok)
        #expect(harness.runner.launches.last?.argv.last == ZmxReplayScript.renderHolding(commandLine: "top"))
    }

    @Test func aStaleExitRecordIsRemovedBeforeThePaneStarts() throws {
        let identity = UUID()
        let session = harness.store.addSession(toWorkspace: harness.store.workspaces[0].id, cwd: "/tmp", select: false)!
        let record = harness.panes.exitRecord(identity)
        try FileManager.default.createDirectory(atPath: (record as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: record, contents: Data("exited\n".utf8))

        #expect(harness.panes.start(.init(identity: identity, session: session, workspace: nil, pane: .left, directory: "/tmp")) == nil)

        #expect(!FileManager.default.fileExists(atPath: record))
    }

    @Test func splitOnStartsTheRightPaneOnceAndOffKeepsIt() throws {
        let session = try harness.session(newSession())

        #expect(harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on").ok)
        let split = try #require(session.splitPaneIdentity)
        #expect(harness.runner.launches.last?.name == ZmxSupport.daemonName(for: split))
        #expect(harness.runner.launches.last?.environment["AGTERM_PANE"] == "right")
        #expect(harness.actions.splitSession(session.id.uuidString, window: nil, mode: "off").ok)
        #expect(harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on").ok)

        #expect(harness.runner.launches.count == 2)
        #expect(harness.runner.kills.isEmpty)
        #expect(session.daemonBackedPanes == [session.paneIdentity, split])
    }

    @Test func closingTheSplitEndsItsDaemon() throws {
        let session = try harness.session(newSession())
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)

        #expect(harness.actions.closeSessionSplit(session.id.uuidString, window: nil).ok)

        #expect(harness.runner.kills == [ZmxSupport.daemonName(for: split)])
        #expect(!session.hasSplit)
    }

    @Test func aSplitThatCannotStartIsTakenBack() throws {
        let session = try harness.session(newSession())
        harness.runner.failure = "zmx: no room"

        let reply = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")

        #expect(reply == ControlResponse(ok: false, error: "could not start the pane: zmx: no room"))
        #expect(!session.hasSplit)
    }

    @Test func closingASessionEndsEveryDaemonOfItsGroup() async throws {
        let session = try harness.session(newSession())
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let companion = try harness.session(await harness.actions.createCompanion(session.id.uuidString,
                                                                                 options: CompanionOptions(), window: nil))
        let names = Set([session.paneIdentity, session.splitPaneIdentity!, companion.paneIdentity].map(ZmxSupport.daemonName(for:)))

        let reply = harness.actions.closeSession(session.id.uuidString, window: nil)

        #expect(reply.result?.closed.map(Set.init) == Set([session.id.uuidString, companion.id.uuidString]))
        #expect(Set(harness.runner.kills) == names)
    }

    @Test func aSessionWhoseDaemonCannotBeKilledStillCloses() throws {
        let session = try harness.session(newSession())
        harness.runner.killFails = true

        #expect(harness.actions.closeSession(session.id.uuidString, window: nil).ok)

        #expect(harness.runner.kills == [ZmxSupport.daemonName(for: session.paneIdentity)])
        #expect(harness.store.session(withID: session.id) == nil)
    }

    @Test func aCompanionStartsItsOwnDaemonAndNamesItsParent() async throws {
        let parent = try harness.session(newSession())

        let reply = await harness.actions.createCompanion(parent.id.uuidString, options: CompanionOptions(command: "top"), window: nil)

        let companion = try harness.session(reply)
        #expect(reply.result?.parent == parent.id.uuidString)
        #expect(harness.runner.launches.last?.name == ZmxSupport.daemonName(for: companion.paneIdentity))
        #expect(harness.runner.launches.last?.argv.last == ZmxReplayScript.renderEnding(commandLine: "top"))
    }

    @Test func swapNeedsASplit() async throws {
        let session = try harness.session(newSession())

        #expect(await harness.actions.swapSessionPanes(session.id.uuidString, window: nil)
            == ControlResponse(ok: false, error: "session has no split"))
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let left = session.paneIdentity
        #expect(await harness.actions.swapSessionPanes(session.id.uuidString, window: nil).ok)
        #expect(session.splitPaneIdentity == left)
    }

    @Test func renameNamesTheSession() throws {
        let session = try harness.session(newSession())

        #expect(harness.actions.renameSession(session.id.uuidString, window: nil, name: "build").ok)

        #expect(session.customName == "build")
    }

    @Test func textReadsTheDaemonsScreen() throws {
        let session = try harness.session(newSession())
        harness.runner.screens[ZmxSupport.daemonName(for: session.paneIdentity)] = "one\ntwo\nthree\n"

        let all = harness.actions.readSessionText(session.id.uuidString, window: nil,
                                                  options: ControlSessionTextOptions(pane: nil, paneID: nil, all: false, lines: nil))
        let last = harness.actions.readSessionText(session.id.uuidString, window: nil,
                                                   options: ControlSessionTextOptions(pane: nil, paneID: nil, all: false, lines: 1))

        #expect(all.result?.text == "one\ntwo\nthree\n")
        #expect(last.result?.text == "three")
    }

    @Test func textLinesReachScrollbackAboveTheScreen() throws {
        let session = try harness.session(newSession())
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        harness.runner.histories[daemon] = "old1\nold2\n"
        harness.runner.screens[daemon] = "now\n"

        let reply = harness.actions.readSessionText(session.id.uuidString, window: nil,
                                                    options: ControlSessionTextOptions(pane: nil, paneID: nil, all: false, lines: 3))

        #expect(reply.result?.text == "old1\nold2\nnow")
    }

    @Test func cursorReadsTheColumnFromThePaneDaemonsScreen() throws {
        let session = try harness.session(newSession())
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        harness.runner.screens[daemon] = "$ ls"
        harness.runner.cursorColumns[daemon] = 4
        let id = TerminalSurfaceID(sessionID: session.id, surface: .primary).rawValue

        let reply = harness.actions.readSurfaceCursor(id, window: nil, paneID: nil)

        #expect(reply == ControlResponse(ok: true, result: ControlResult(id: id, cursor: ControlCursor(column: 4))))
    }

    @Test func cursorByPaneIDReadsTheSplitAndNamesItsSurface() throws {
        let session = try harness.session(newSession())
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)
        harness.runner.screens[ZmxSupport.daemonName(for: split)] = ""
        harness.runner.cursorColumns[ZmxSupport.daemonName(for: split)] = 9

        let reply = harness.actions.readSurfaceCursor(session.id.uuidString, window: nil, paneID: split.uuidString)

        #expect(reply.result?.cursor == ControlCursor(column: 9))
        #expect(reply.result?.id == TerminalSurfaceID(sessionID: session.id, surface: .split).rawValue)
    }

    @Test func activeCursorReadsTheSelectedSessionsFocusedPane() throws {
        let session = try harness.session(newSession())
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)
        harness.runner.screens[ZmxSupport.daemonName(for: session.paneIdentity)] = ""
        harness.runner.screens[ZmxSupport.daemonName(for: split)] = ""
        harness.runner.cursorColumns[ZmxSupport.daemonName(for: split)] = 2
        _ = harness.store.selectSession(session.id)
        session.splitFocused = true

        let reply = harness.actions.readSurfaceCursor(nil, window: nil, paneID: nil)

        #expect(reply.result?.cursor == ControlCursor(column: 2))
        #expect(reply.result?.id == TerminalSurfaceID(sessionID: session.id, surface: .split).rawValue)
    }

    @Test(arguments: ["overlay", "overlay-left", "scratch"])
    func cursorOfASurfaceWithNoDaemonIsRefused(_ kind: String) throws {
        let session = try harness.session(newSession())
        let id = "surface:\(session.id.uuidString):\(kind)"

        let reply = harness.actions.readSurfaceCursor(id, window: nil, paneID: nil)

        #expect(!reply.ok)
        #expect(reply.error == (kind == "scratch" ? "session not realized" : "surface not available: \(id)"))
    }

    @Test func cursorRefusesQuickASurfaceIDBesideAPaneIDAndAnUnknownToken() throws {
        let session = try harness.session(newSession())
        let id = TerminalSurfaceID(sessionID: session.id, surface: .primary).rawValue

        #expect(harness.actions.readSurfaceCursor("quick", window: nil, paneID: nil).error == "surface not available: quick")
        #expect(harness.actions.readSurfaceCursor(id, window: nil, paneID: "tok").error
            == "surface.cursor: --pane-id takes a session target")
        #expect(harness.actions.readSurfaceCursor(session.id.uuidString, window: nil, paneID: "tok").error == "unknown pane id: tok")
        #expect(harness.actions.readSurfaceCursor("nonsense", window: nil, paneID: nil).error == "invalid surface: nonsense")
    }

    @Test func textOfAPaneWithNoDaemonIsNotRealized() throws {
        let session = try harness.session(newSession())

        let reply = harness.actions.readSessionText(session.id.uuidString, window: nil,
                                                    options: ControlSessionTextOptions(pane: .right, paneID: nil, all: false, lines: nil))

        #expect(reply == ControlResponse(ok: false, error: "session not realized"))
    }

    @Test func typeSendsTheTextThenItsFinalReturnApart() async throws {
        let session = try harness.session(newSession())
        let name = ZmxSupport.daemonName(for: session.paneIdentity)

        let reply = await harness.actions.typeSession(session.id.uuidString, window: nil,
                                                      options: ControlSessionTypeOptions(text: "ls\n", select: false, pane: nil, paneID: nil))

        #expect(reply.result?.pane == "left")
        #expect(harness.runner.typed.map(\.name) == [name, name])
        #expect(harness.runner.typed.map(\.bytes) == [Array("ls".utf8), [0x0D]])
    }

    @Test func typeIntoTheOwningPaneClearsItsBlockedStatus() async throws {
        let session = try harness.session(newSession())
        harness.store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)

        _ = await harness.actions.typeSession(session.id.uuidString, window: nil,
                                              options: ControlSessionTypeOptions(text: "y\n", select: false, pane: nil, paneID: nil))

        #expect(session.agentIndicator.status == .idle)
    }

    @Test func typeIntoAnotherPaneKeepsTheBlockedStatus() async throws {
        let session = try harness.session(newSession())
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        harness.store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)

        _ = await harness.actions.typeSession(session.id.uuidString, window: nil,
                                              options: ControlSessionTypeOptions(text: "y\n", select: false, pane: .right, paneID: nil))

        #expect(session.agentIndicator.status == .blocked)
    }

    @Test func typeByPaneIDFindsTheSplit() async throws {
        let session = try harness.session(newSession())
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)

        let reply = await harness.actions.typeSession(session.id.uuidString, window: nil,
                                                      options: ControlSessionTypeOptions(text: "x", select: false, pane: nil,
                                                                                         paneID: split.uuidString))

        #expect(reply.result?.pane == "right")
        #expect(harness.runner.typed.first?.name == ZmxSupport.daemonName(for: split))
    }

    @Test func anUnknownSessionIsNamed() {
        let target = UUID().uuidString

        #expect(harness.actions.renameSession(target, window: nil, name: "x")
            == ControlResponse(ok: false, error: ControlResolve.notFoundMessage(noun: "session", target: target)))
    }

    private func pageRow(_ cmd: Command, target: String, url: String = "https://example.com/") async -> ControlResponse {
        var args = ControlArgs()
        args.url = url
        return await harness.actions.serve(ControlRequest(cmd: cmd, target: target, args: args))
    }

    @Test func pageSessionsAndPageCompanionsAreRowsWithNoDaemon() async throws {
        let anchor = try harness.session(newSession())
        let launches = harness.runner.launches.count

        let root = await pageRow(.sessionPage, target: anchor.id.uuidString)
        let companion = await pageRow(.sessionCompanionPage, target: anchor.id.uuidString)

        let rootRow = try harness.session(root)
        let companionRow = try harness.session(companion)
        #expect(root.result?.pageID == rootRow.htmlOverlay?.id.uuidString)
        #expect(rootRow.content == .page && rootRow.parentID == nil)
        #expect(companionRow.content == .page && companionRow.parentID == anchor.id)
        #expect(companion.result?.parent == anchor.id.uuidString)
        #expect(rootRow.htmlOverlay?.source == .url(try #require(URL(string: "https://example.com/"))))
        #expect(harness.runner.launches.count == launches)
        let nodes = harness.store.controlTree().workspaces.flatMap(\.sessions)
        #expect(nodes.filter { $0.content == "page" }.count == 2)
    }

    @Test func aLoopbackPageRowIsRefusedAtCreation() async throws {
        let anchor = try harness.session(newSession())
        let count = harness.store.workspaces.flatMap(\.sessions).count

        let root = await pageRow(.sessionPage, target: anchor.id.uuidString, url: "http://localhost:3000/")
        let companion = await pageRow(.sessionCompanionPage, target: anchor.id.uuidString, url: "http://127.0.0.1:8080/")

        #expect(root == ControlResponse(ok: false, error: OverlayHtmlError.serverLoopbackRow))
        #expect(companion == ControlResponse(ok: false, error: OverlayHtmlError.serverLoopbackRow))
        #expect(harness.store.workspaces.flatMap(\.sessions).count == count)
    }

    @Test func terminalCommandsOnAPageRowAreRefusedAGuiAskIsTakenAndTextCommandsFindNoTextPage() async throws {
        let anchor = try harness.session(newSession())
        let row = try harness.session(await pageRow(.sessionPage, target: anchor.id.uuidString)).id.uuidString
        var typed = ControlArgs()
        typed.text = "ls\n"
        var split = ControlArgs()
        split.mode = "on"
        var hud = ControlArgs()
        hud.message = "hi"
        var program = ControlArgs()
        program.command = "true"
        var ask = ControlArgs()
        ask.title = "sure?"
        ask.buttons = [ControlAskButton(id: "yes", label: "Yes")]
        var gui = ask
        gui.style = "gui"
        let refused: [(Command, ControlArgs?)] = [(.sessionType, typed), (.sessionText, nil), (.sessionSplit, split),
                                                  (.sessionScratch, split), (.sessionHudOpen, hud),
                                                  (.sessionOverlayOpen, program), (.askOpen, ask)]

        for (cmd, args) in refused {
            let reply = await harness.actions.serve(ControlRequest(cmd: cmd, target: row, args: args))
            #expect(reply == ControlResponse(ok: false, error: "\(cmd.rawValue): not available on a page session"))
        }
        let guiAsk = await harness.actions.serve(ControlRequest(cmd: .askOpen, target: row, args: gui))
        #expect(guiAsk.ok, "\(guiAsk)")
        let follow = await harness.actions.setSessionOverlayFollow(row, window: nil, pane: nil, mode: .on)
        let wrap = await harness.actions.setSessionOverlayWrap(row, window: nil, pane: nil, mode: .on)
        let search = await harness.actions.searchSessionOverlay(row, window: nil, pane: nil, request: .next)
        let changes = await harness.actions.stepSessionOverlayChanges(row, window: nil, pane: nil, forward: true)
        #expect([follow, wrap, search, changes].map(\.error) == [TextLogFollowFailure.notLog.message, TextWrapFailure.notText.message,
                                                                 TextSearchFailure.notText.message, TextChangesFailure.notDiff.message])
    }

    @Test func aPageRowIsSavedAndReopenedOnRestart() async throws {
        let anchor = try harness.session(newSession())
        var args = ControlArgs()
        args.url = "https://example.com/docs"
        args.javascript = true
        let row = try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionPage, target: anchor.id.uuidString,
                                                                                  args: args)))
        harness.store.save()

        let restarted = AppStore(persistence: PersistenceStore(directory: URL(fileURLWithPath: harness.scratch.state)),
                                 paneFinalizer: nil, headless: true, askRegistry: AskRegistry())
        restarted.restore(from: try PersistenceStore(directory: URL(fileURLWithPath: harness.scratch.state)).loadChecked())

        let restored = try #require(restarted.session(withID: row.id))
        #expect(restored.content == .page)
        #expect(restored.htmlOverlay?.source == row.htmlOverlay?.source)
        #expect(restored.htmlOverlay?.javascript == true)
    }

    @Test func aDuplicateIsAPlainShellRightAfterTheSourceInItsDirectory() throws {
        let source = try harness.session(newSession(command: "top", cwd: harness.scratch.root))
        let next = try harness.session(newSession())
        harness.store.renameSession(source.id, to: "build")
        harness.store.setFlag(true, forSession: source.id)

        let copy = try harness.session(harness.actions.duplicateSession(source.id.uuidString, window: nil))

        #expect(harness.store.workspaces[0].sessions.map(\.id).suffix(3) == [source.id, copy.id, next.id])
        #expect(harness.runner.launches.last?.directory == harness.scratch.root)
        #expect(harness.runner.launches.last?.argv.isEmpty == true)
        #expect(copy.customName == nil)
        #expect(!copy.flagged)
    }
}
