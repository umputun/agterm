import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerTextPageTests: XCTestCase {
    private final class PresenterSink: PresentationSink {
        var generation = 0
        var opened = false

        func offer(_ frame: PresentationFrame) -> Bool {
            if !opened { generation = frame.gen }
            opened = true
            return true
        }

        func close(_: PresentationHub.CloseReason) {}
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var log: URL!

    override func setUp() async throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-control-text-tests-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        library = WindowLibrary(directory: stateDir)
        let actions = AppActions(library: library)
        server = ControlServer(library: library, actions: actions,
                               settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                               identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                               socketPath: stateDir.appendingPathComponent("control.sock").path)
        log = stateDir.appendingPathComponent("app.log")
        try Data("one\ntwo\n".utf8).write(to: log)
    }

    override func tearDown() async throws {
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory())))
    }

    private func options(_ path: String, log textLog: TextLog?) -> ControlSessionOverlayOpenOptions {
        ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                         page: .text(path: path, line: nil), textLog: textLog)
    }

    private func present(_ session: Session) throws {
        for pane in [session.paneIdentity] + [session.splitPaneIdentity].compactMap({ $0 }) {
            ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: pane)
            _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:follower:1")), pane: pane)
        }
        server.attachPresentationHub()
        let sink = PresenterSink()
        let id = try server.presentationHub.subscribe(
            session: session.id, hello: PresentationHello(version: 1, kinds: PresentationHub.pageKinds + [PresentationHub.pageContentKind], mode: .presenter), sink: sink
        ) { PresentationSnapshot(status: nil, hud: nil) }
        server.presentationHub.receive(PresentationFrame(gen: sink.generation, rev: 0, body: .presenterAcquire), from: id)
    }

    func testALogPageOpensWithItsRequestOnTheModel() throws {
        let (_, session) = try addSession()

        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                 options: options(log.path, log: TextLog(tail: 20, follow: true)))

        XCTAssertTrue(response.ok, String(describing: response.error))
        XCTAssertEqual(session.htmlOverlay?.textLog, TextLog(tail: 20, follow: true))
        XCTAssertEqual(session.htmlOverlay?.logState?.following, true)
    }

    func testALogOverTheWholeFileCapOpensWhileAPlainTextPageIsRefused() throws {
        let (_, session) = try addSession()
        let big = stateDir.appendingPathComponent("big.log")
        let line = String(repeating: "x", count: 99) + "\n"
        try Data(String(repeating: line, count: TextPage.maxBytes / 100 + 10).utf8).write(to: big)

        let plain = server.openSessionOverlay(session.id.uuidString, window: nil, options: options(big.path, log: nil))
        XCTAssertEqual(plain.error, "session.overlay.open: \(TextProbe.Failure.tooLarge(big.path))")

        let tail = server.openSessionOverlay(session.id.uuidString, window: nil,
                                             options: options(big.path, log: TextLog(tail: 10, follow: false)))
        XCTAssertTrue(tail.ok, String(describing: tail.error))
    }

    func testALogPageIsRefusedOnAPresentedSessionAndAPlainTextPageIsNot() throws {
        let (_, session) = try addSession()
        try present(session)

        let refused = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                options: options(log.path, log: TextLog(tail: 20, follow: true)))
        XCTAssertEqual(refused, ControlResponse(ok: false, error: OverlayHtmlError.logRemote))
        XCTAssertNil(session.htmlOverlay)
        XCTAssertTrue(session.remoteOverlays.slots.isEmpty)

        let plain = server.openSessionOverlay(session.id.uuidString, window: nil, options: options(log.path, log: nil))
        XCTAssertTrue(plain.ok, String(describing: plain.error))
    }

    func testFollowAnswersTheStateItLeftOnTheModel() throws {
        let (_, session) = try addSession()
        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil,
                                                options: options(log.path, log: TextLog(tail: 20, follow: true))).ok)

        let paused = server.setSessionOverlayFollow(session.id.uuidString, window: nil, pane: nil, mode: .toggle)

        XCTAssertEqual(paused, ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString, text: "paused")))
        XCTAssertEqual(session.htmlOverlay?.logState?.following, false)
        XCTAssertEqual(server.setSessionOverlayFollow(session.id.uuidString, window: nil, pane: nil, mode: .on).result?.text,
                       "following")
    }

    func testFollowRefusesAPlainTextPageAndAnEmptySlot() throws {
        let (_, session) = try addSession()
        XCTAssertEqual(server.setSessionOverlayFollow(session.id.uuidString, window: nil, pane: nil, mode: .on).error,
                       OverlayHtmlError.noOverlay)
        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil, options: options(log.path, log: nil)).ok)

        XCTAssertEqual(server.setSessionOverlayFollow(session.id.uuidString, window: nil, pane: nil, mode: .on).error,
                       "no log page")
    }

    func testSearchSetsAndClosesTheQueryOnTheModelAndItsReadBack() async throws {
        let (_, session) = try addSession()
        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil, options: options(log.path, log: nil)).ok)

        let set = await server.searchSessionOverlay(session.id.uuidString, window: nil, pane: nil, request: .query("two"))

        XCTAssertEqual(set, ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString)))
        XCTAssertEqual(session.htmlOverlay?.textSearch, TextSearch(query: "two"))
        XCTAssertEqual(try treeSearch(session), ControlTextSearchNode(query: "two", matches: 0, current: 0))

        let closed = await server.searchSessionOverlay(session.id.uuidString, window: nil, pane: nil, request: .close)
        XCTAssertTrue(closed.ok)
        XCTAssertNil(session.htmlOverlay?.textSearch)
        XCTAssertNil(try treeSearch(session))
    }

    private func treeSearch(_ session: Session) throws -> ControlTextSearchNode? {
        let tree = try XCTUnwrap(server.controlTree(window: nil).result?.tree)
        let node = try XCTUnwrap(tree.workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
        return node.htmlOverlays?.first?.text?.search
    }

    func testAStepNeedsAQueryAndALoadedPage() async throws {
        let (_, session) = try addSession()
        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil, options: options(log.path, log: nil)).ok)

        let noQuery = await server.searchSessionOverlay(session.id.uuidString, window: nil, pane: nil, request: .next)
        XCTAssertEqual(noQuery.error, TextSearchFailure.noQuery.message)

        _ = await server.searchSessionOverlay(session.id.uuidString, window: nil, pane: nil, request: .query("one"))
        let notLoaded = await server.searchSessionOverlay(session.id.uuidString, window: nil, pane: nil, request: .previous)
        XCTAssertEqual(notLoaded.error, TextSearchFailure.notLoaded.message)
    }

    func testSearchRefusesAnEmptySlotAndAPresentedPage() async throws {
        let (_, session) = try addSession()
        let empty = await server.searchSessionOverlay(session.id.uuidString, window: nil, pane: nil, request: .query("a"))
        XCTAssertEqual(empty.error, OverlayHtmlError.noOverlay)

        try present(session)
        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil, options: options(log.path, log: nil)).ok)

        let remote = await server.searchSessionOverlay(session.id.uuidString, window: nil, pane: nil, request: .query("a"))
        XCTAssertEqual(remote.error, TextSearchFailure.remote.message)
    }

    func testAChangesStepNeedsALoadedDiffPage() async throws {
        let (_, session) = try addSession()
        let empty = await server.stepSessionOverlayChanges(session.id.uuidString, window: nil, pane: nil, forward: true)
        XCTAssertEqual(empty.error, OverlayHtmlError.noOverlay)

        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil, options: options(log.path, log: nil)).ok)
        let plain = await server.stepSessionOverlayChanges(session.id.uuidString, window: nil, pane: nil, forward: true)
        XCTAssertEqual(plain.error, TextChangesFailure.notDiff.message)
        XCTAssertTrue(server.closeSessionOverlay(session.id.uuidString, window: nil, pane: nil).ok)

        let patch = stateDir.appendingPathComponent("a.diff")
        try Data("@@ -1 +1 @@\n-a\n+b\n".utf8).write(to: patch)
        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil, options: options(patch.path, log: nil)).ok)
        let notLoaded = await server.stepSessionOverlayChanges(session.id.uuidString, window: nil, pane: nil, forward: false)
        XCTAssertEqual(notLoaded.error, TextChangesFailure.notLoaded.message)
    }
}
