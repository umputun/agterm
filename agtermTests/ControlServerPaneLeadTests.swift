import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerPaneLeadTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var invocations: [ZmxClient.Invocation] = []
    private var zmxReply: (ZmxClient.Invocation) throws -> String = { _ in "" }
    private var panes: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-pane-lead-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
    }

    override func tearDown() async throws {
        panes.forEach(ZmxLeadBook.shared.forget)
        PaneLead.reattach = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func makeServer(zmx: Bool = true) -> ControlServer {
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { [unowned self] in
            invocations.append($0)
            return try zmxReply($0)
        }
        return ControlServer(library: library, actions: AppActions(library: library),
                             settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                             identity: AppIdentity(version: "test", commit: "test"), zmxClient: zmx ? client : nil,
                             socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    /// A pane in `role`, local (its own daemon) or attached from another Mac.
    private func pane(role: ZmxLeadRole?, local: Bool = true) throws -> (GhosttySurfaceView, UUID) {
        let identity = UUID()
        panes.append(identity)
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                      env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: local)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: identity)
        if let role {
            _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:\(role.rawValue):1")),
                                         pane: identity)
        }
        return (view, identity)
    }

    // pins a swap during the realize wait sending an id's keystrokes to the terminal that took its slot
    func testTypeByPaneIDReachesItsTerminalAfterASwapDuringTheRealizeWait() async throws {
        let server = makeServer()
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID),
                                                     cwd: NSHomeDirectory()))
        let (target, identity) = try pane(role: nil)
        let (other, _) = try pane(role: nil)
        session.surface = target
        session.splitSurface = other
        session.hasSplit = true
        let registry = SpawnRegistry(pacer: SpawnPacer())
        let key = UUID()
        registry.pacer.arm(order: [UUID(), key], burst: [])
        registry.enqueue(target, key: key, provider: LaunchSeedProvider(shouldPace: true) { _ in
            LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        })
        XCTAssertFalse(target.requestSpawnPermit())
        let grant = registry.pacer.onGrant
        registry.pacer.onGrant = { granted in
            grant?(granted)
            XCTAssertNil(store.swapPanes(session.id))
            _ = ZmxLeadNotice(title: "zmx-role;n:leader:1").map { ZmxLeadBook.shared.apply($0, pane: identity) }
        }

        let typed = await server.typeSession(session.id.uuidString, window: nil,
                                             options: ControlSessionTypeOptions(text: "x", select: false, pane: nil,
                                                                                paneID: identity.uuidString))

        XCTAssertTrue(typed.ok, typed.error ?? "")
        XCTAssertEqual(typed.result?.pane, "right")
        XCTAssertEqual(invocations.map(\.arguments), [["type", ZmxSupport.daemonName(for: identity)]])
    }

    // pins a swap during the realize wait ending the wait while the id's terminal is still coming up
    func testTypeByPaneIDKeepsWaitingForItsTerminalAfterASwap() async throws {
        let server = makeServer()
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID),
                                                     cwd: NSHomeDirectory()))
        let (target, identity) = try pane(role: nil)
        let (other, _) = try pane(role: nil)
        session.surface = target
        session.splitSurface = other
        session.hasSplit = true

        let typing = Task { @MainActor in
            await server.typeSession(session.id.uuidString, window: nil,
                                     options: ControlSessionTypeOptions(text: "x", select: false, pane: nil,
                                                                        paneID: identity.uuidString))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(store.swapPanes(session.id))
        try await Task.sleep(nanoseconds: 60_000_000)
        _ = ZmxLeadNotice(title: "zmx-role;n:leader:1").map { ZmxLeadBook.shared.apply($0, pane: identity) }
        let typed = await typing.value

        XCTAssertTrue(typed.ok, typed.error ?? "")
        XCTAssertEqual(typed.result?.pane, "right")
        XCTAssertEqual(invocations.map(\.arguments), [["type", ZmxSupport.daemonName(for: identity)]])
    }

    func testAPaneWhoseZmxNeverReportedKeepsItsOwnSurfaceForEverything() throws {
        let server = makeServer()
        let (view, _) = try pane(role: nil)

        XCTAssertNil(server.coveredText(view, all: false, lines: 3))
        XCTAssertNil(server.coveredCursor(view, controlID: "x"))
        XCTAssertNil(server.coveredType("ls\n", into: view, session: UUID()))
        XCTAssertTrue(invocations.isEmpty)
    }

    // the role the app holds trails the daemon's, so it never decides whether input is delivered.
    func testALeadingPaneStillTypesAndReadsItsLayoutThroughTheDaemon() throws {
        let server = makeServer()
        let (view, identity) = try pane(role: .leader)
        zmxReply = { $0.arguments.first == "screen" ? "1 80 24 5 0 0\nprompt\n" : "" }

        XCTAssertNil(server.coveredText(view, all: false, lines: nil), "its scrolled viewport is its own")
        XCTAssertEqual(server.coveredText(view, all: false, lines: 1)?.result?.text, "prompt")
        XCTAssertEqual(server.coveredCursor(view, controlID: "x")?.result?.cursor?.column, 5)
        XCTAssertEqual(server.coveredType("ls\n", into: view, session: UUID())?.ok, true)

        let name = ZmxSupport.daemonName(for: identity)
        XCTAssertEqual(invocations.map(\.arguments), [["screen", name, "--all"], ["screen", name], ["type", name], ["type", name]])
    }

    func testALeadingPaneAttachedFromAnotherMacIsDrivenThroughItsOwnSurface() throws {
        let server = makeServer()
        let (view, _) = try pane(role: .leader, local: false)

        XCTAssertNil(server.coveredText(view, all: true, lines: nil))
        XCTAssertNil(server.coveredCursor(view, controlID: "x"))
        XCTAssertNil(server.coveredType("ls\n", into: view, session: UUID()))
    }

    func testACoveredLocalPaneIsReadFromItsDaemon() throws {
        let server = makeServer()
        let (view, identity) = try pane(role: .follower)
        zmxReply = { _ in "9 101 33 2 4 0\nfirst\n> draft\n\n" }

        let viewport = try XCTUnwrap(server.coveredText(view, all: false, lines: nil))
        let tail = try XCTUnwrap(server.coveredText(view, all: false, lines: 1))
        let cursor = try XCTUnwrap(server.coveredCursor(view, controlID: "surface:s:left"))

        let name = ZmxSupport.daemonName(for: identity)
        XCTAssertEqual(invocations.map(\.arguments), [["screen", name], ["screen", name, "--all"], ["screen", name]],
                       "--lines reads scrollback, like the pane's own surface does")
        XCTAssertEqual(viewport.result?.text, "first\n> draft\n\n")
        XCTAssertEqual(tail.result?.text, "> draft")
        XCTAssertEqual(cursor.result?.cursor?.column, 2)
        XCTAssertEqual(cursor.result?.id, "surface:s:left")
    }

    func testAFailedDaemonReadIsAnErrorNeverTheCoveredSurface() throws {
        let server = makeServer()
        let (view, _) = try pane(role: .unowned)
        zmxReply = { _ in throw ZmxClient.CommandError.timedOut }

        XCTAssertEqual(server.coveredText(view, all: true, lines: nil),
                       ControlResponse(ok: false, error: "failed to read surface buffer"))
        XCTAssertEqual(server.coveredCursor(view, controlID: "x"),
                       ControlResponse(ok: false, error: "failed to read cursor position"))
    }

    func testTypingIntoACoveredPaneGoesThroughTheDaemonByteForByte() throws {
        let server = makeServer()
        let (view, identity) = try pane(role: .follower)
        let session = UUID()
        var cleared: [StatusKeystroke] = []
        view.onUserInputClearsStatus = { cleared.append($0) }

        XCTAssertEqual(server.coveredType("echo hi\r\n", into: view, session: session),
                       ControlResponse(ok: true, result: ControlResult(id: session.uuidString)))
        XCTAssertEqual(server.coveredType("\n", into: view, session: session)?.ok, true)

        XCTAssertEqual(invocations.map(\.arguments), Array(repeating: ["type", ZmxSupport.daemonName(for: identity)], count: 3))
        XCTAssertEqual(invocations.map(\.input), [Data("echo hi".utf8), Data([0x0D]), Data([0x0D])],
                       "the final Return after text is its own call; a bare Return stays one")
        XCTAssertEqual(cleared.count, 2, "the input a blocked agent waited for clears its status, as typing does")

        zmxReply = { _ in throw ZmxClient.CommandError.failed(1, "error: type rejected") }
        XCTAssertEqual(server.coveredType("lost", into: view, session: session),
                       ControlResponse(ok: false, error: "the pane's zmx daemon did not accept the input"),
                       "input the daemon did not queue must never answer ok")
    }

    func testAFinalReturnTheDaemonDidNotConfirmIsAnErrorAndIsNeverRetried() throws {
        let server = makeServer()
        let (view, _) = try pane(role: .leader)
        var cleared: [StatusKeystroke] = []
        view.onUserInputClearsStatus = { cleared.append($0) }
        view._markedText = "ni"
        view._markedRange = NSRange(location: 0, length: 2)
        zmxReply = { [unowned self] _ in
            if invocations.count == 2 { throw ZmxClient.CommandError.timedOut }
            return ""
        }

        XCTAssertEqual(server.coveredType("one\ntwo\n", into: view, session: UUID()),
                       ControlResponse(ok: false, error: "text typed, but its final Return could not be confirmed; do not retype the text"))
        XCTAssertEqual(invocations.map(\.input), [Data("nione\rtwo".utf8), Data([0x0D])])
        XCTAssertEqual(view.pendingComposition, "", "the composition went with the text the daemon took")
        XCTAssertTrue(cleared.isEmpty, "the call errored and the agent may still wait for its Return, so its status stays")
    }

    func testAPendingCompositionIsTypedFirstAndDroppedOnlyOnceTheDaemonTookIt() throws {
        let server = makeServer()
        let (view, _) = try pane(role: .leader)
        // set directly: `setMarkedText` needs a live libghostty surface, which a hosted test has none of
        view._markedText = "ni"
        view._markedRange = NSRange(location: 0, length: 2)

        zmxReply = { _ in throw ZmxClient.CommandError.timedOut }
        XCTAssertEqual(server.coveredType("hao\n", into: view, session: UUID())?.ok, false)
        XCTAssertEqual(view.pendingComposition, "ni", "input that was not delivered leaves the composition alone")

        zmxReply = { _ in "" }
        XCTAssertEqual(server.coveredType("hao\n", into: view, session: UUID())?.ok, true)
        XCTAssertEqual(invocations.suffix(2).map(\.input), [Data("nihao".utf8), Data([0x0D])])
        XCTAssertEqual(view.pendingComposition, "")
    }

    func testACoveredPaneAttachedFromAnotherMacRefusesInsteadOfAnsweringWrong() throws {
        let server = makeServer()
        let (view, _) = try pane(role: .follower, local: false)
        let refusal = ControlResponse(ok: false,
                                      error: "pane is in use on the Mac it runs on; take the lead to drive it from here")

        XCTAssertEqual(server.coveredText(view, all: false, lines: nil), refusal)
        XCTAssertEqual(server.coveredCursor(view, controlID: "x"), refusal)
        XCTAssertEqual(server.coveredType("ls\n", into: view, session: UUID()), refusal)
        XCTAssertTrue(invocations.isEmpty)
    }

    func testCommandsThatActOnThePanesOwnSurfaceAreRefusedWhileItIsCovered() async throws {
        let server = makeServer()
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID),
                                                     cwd: NSHomeDirectory()))
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                      env: ["AGTERM_PANE_ID": session.paneIdentity.uuidString], backedByZmx: true)
        session.surface = view
        panes.append(session.paneIdentity)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: session.paneIdentity)
        _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:follower:1")),
                                     pane: session.paneIdentity)
        let refusal = "pane is covered while another Mac leads it; take the lead first (session lead)"
        let id = session.id.uuidString

        XCTAssertEqual(server.pasteSession(id, window: nil, pane: nil).error, refusal)
        XCTAssertEqual(server.selectAllSession(id, window: nil).error, refusal)
        let opened = await server.searchSession(session.id, store: store, text: "needle", to: nil)
        XCTAssertEqual(opened.error, refusal)
        let closed = await server.searchSession(session.id, store: store, text: nil, to: "close")
        XCTAssertTrue(closed.ok, "closing a search is cleanup, not a read of the covered grid")
        XCTAssertEqual(server.coveredRefusal(view)?.ok, false)
    }

    func testASearchWhosePaneIsDemotedWhileItWaitsIsRefusedNotAnswered() async throws {
        let server = makeServer()
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID),
                                                     cwd: NSHomeDirectory()))
        let identity = session.paneIdentity
        session.surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                             env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        panes.append(identity)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: identity)
        _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:leader:1")), pane: identity)
        let demotion = try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:follower:2"))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) {
            _ = ZmxLeadBook.shared.apply(demotion, pane: identity)
        }

        let searched = await server.searchSession(session.id, store: store, text: "needle", to: nil)

        XCTAssertEqual(searched.error, "pane is covered while another Mac leads it; take the lead first (session lead)")
        XCTAssertNotEqual(session.searchNeedle, "needle")
    }

    func testAnOpenSearchOnALeadingPaneStaysDrivableWhileFocusSitsOnACoveredSplit() async throws {
        let server = makeServer()
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID),
                                                     cwd: NSHomeDirectory()))
        let split = UUID()
        let owner = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                       env: ["AGTERM_PANE_ID": session.paneIdentity.uuidString], backedByZmx: true)
        session.surface = owner
        session.splitSurface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                                  env: ["AGTERM_PANE_ID": split.uuidString], backedByZmx: true)
        session.splitPaneIdentity = split
        session.splitFocused = true
        session.searchActive = true
        session.searchSurface = owner
        for (identity, role) in [(session.paneIdentity, "leader"), (split, "follower")] {
            panes.append(identity)
            ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: identity)
            _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:\(role):1")), pane: identity)
        }

        let next = await server.searchSession(session.id, store: store, text: nil, to: "next")

        XCTAssertTrue(next.ok, next.error ?? "")
    }

    func testSessionLeadReattachesOnlyACoveredPane() throws {
        let server = makeServer()
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID),
                                                     cwd: NSHomeDirectory()))
        var claims: [Bool] = []
        PaneLead.reattach = { _, claim in claims.append(claim) }
        func lead(_ role: ZmxLeadRole?) throws -> ControlResponse {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                          env: ["AGTERM_PANE_ID": session.paneIdentity.uuidString], backedByZmx: true)
            session.surface = view
            panes.append(session.paneIdentity)
            ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: session.paneIdentity)
            if let role {
                _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:\(role.rawValue):1")),
                                             pane: session.paneIdentity)
            }
            return server.takeSessionLead(session.id.uuidString, window: nil, pane: nil)
        }

        XCTAssertEqual(try lead(.follower).result?.id, session.id.uuidString)
        XCTAssertEqual(claims, [true])
        XCTAssertEqual(try lead(.leader).ok, true, "already leading is ok, and attaches nothing")
        XCTAssertEqual(claims, [true])
        XCTAssertEqual(try lead(nil), ControlResponse(ok: false, error: "pane has no lead to take"))
        XCTAssertEqual(server.takeSessionLead(session.id.uuidString, window: nil, pane: .right),
                       ControlResponse(ok: false, error: "session has no split pane"))
        XCTAssertEqual(server.takeSessionLead(session.id.uuidString, window: nil, pane: .scratch),
                       ControlResponse(ok: false, error: "the scratch terminal has no lead"))
    }
}
