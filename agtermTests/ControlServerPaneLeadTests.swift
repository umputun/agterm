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
        XCTAssertEqual(invocations.map(\.arguments), [["screen", name, "--all"], ["screen", name], ["type", name]])
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

        XCTAssertEqual(invocations.map(\.arguments), Array(repeating: ["type", ZmxSupport.daemonName(for: identity)], count: 2))
        XCTAssertEqual(invocations.map(\.input), [Data("echo hi\r".utf8), Data([0x0D])])
        XCTAssertEqual(cleared.count, 2, "the input a blocked agent waited for clears its status, as typing does")

        zmxReply = { _ in throw ZmxClient.CommandError.failed(1, "error: type rejected") }
        XCTAssertEqual(server.coveredType("lost", into: view, session: session),
                       ControlResponse(ok: false, error: "the pane's zmx daemon did not accept the input"),
                       "input the daemon did not queue must never answer ok")
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
