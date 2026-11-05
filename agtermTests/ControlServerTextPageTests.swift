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
}
