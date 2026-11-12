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

    @Test func waitIsRefused() {
        let reply = harness.actions.createSession(ControlSessionCreateOptions(window: nil, cwd: nil, workspace: nil,
                                                                              workspaceName: nil, createWorkspace: nil,
                                                                              command: "make", wait: true, name: nil, after: nil,
                                                                              before: nil, noSelect: false))

        #expect(!reply.ok)
        #expect(harness.runner.launches.isEmpty)
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

    @Test func terminalCommandsOnAPageRowAreRefusedAndTextCommandsFindNoTextPage() async throws {
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
                                                  (.sessionOverlayOpen, program), (.askOpen, ask), (.askOpen, gui)]

        for (cmd, args) in refused {
            let reply = await harness.actions.serve(ControlRequest(cmd: cmd, target: row, args: args))
            #expect(reply == ControlResponse(ok: false, error: "\(cmd.rawValue): not available on a page session"))
        }
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
}
