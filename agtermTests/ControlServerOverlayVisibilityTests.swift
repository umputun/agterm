import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerOverlayVisibilityTests: XCTestCase {
    private final class PresenterSink: PresentationSink {
        var generation = 0
        private var started = false

        func offer(_ frame: PresentationFrame) -> Bool {
            if !started { generation = frame.gen }
            started = true
            return true
        }

        func close(_: PresentationHub.CloseReason) {}
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-overlay-visibility-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            socketPath: stateDir.appendingPathComponent("control.sock").path
        )
    }

    override func tearDown() async throws {
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory())))
    }

    private func options(pane: OverlayPane? = nil, page: HtmlSource? = nil) -> ControlSessionOverlayOpenOptions {
        ControlSessionOverlayOpenOptions(command: page == nil ? "true" : "", cwd: nil, wait: false, sizePercent: nil,
                                         backgroundColor: nil, follow: false, pane: pane, page: page)
    }

    func testHideShowAndToggleReportTheStateTheyLeave() throws {
        let (_, session) = try addSession()
        let target = session.id.uuidString
        XCTAssertTrue(server.openSessionOverlay(target, window: nil, options: options()).ok)

        let hidden = server.setSessionOverlayVisibility(target, window: nil, pane: nil, mode: .hide)
        XCTAssertEqual(hidden, ControlResponse(ok: true, result: ControlResult(id: target, text: "hidden")))
        XCTAssertTrue(session.overlayHidden)
        XCTAssertTrue(session.overlayActive)

        let toggled = server.setSessionOverlayVisibility(target, window: nil, pane: nil, mode: .toggle)
        XCTAssertEqual(toggled.result?.text, "shown")
        XCTAssertFalse(session.overlayHidden)

        let shown = server.setSessionOverlayVisibility(target, window: nil, pane: nil, mode: .show)
        XCTAssertEqual(shown.result?.text, "shown")
    }

    func testVisibilityRefusesAnEmptySessionAndAnUnknownTarget() throws {
        let (_, session) = try addSession()

        let empty = server.setSessionOverlayVisibility(session.id.uuidString, window: nil, pane: nil, mode: .toggle)
        XCTAssertEqual(empty, ControlResponse(ok: false, error: OverlayVisibilityError.noOverlay))

        let unknown = server.setSessionOverlayVisibility("nope", window: nil, pane: nil, mode: .hide)
        XCTAssertFalse(unknown.ok)
    }

    func testOpeningIntoAHiddenSessionSlotIsRefusedByName() throws {
        let (store, session) = try addSession()
        let target = session.id.uuidString
        XCTAssertTrue(server.openSessionOverlay(target, window: nil, options: options()).ok)
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)

        let program = server.openSessionOverlay(target, window: nil, options: options())
        let page = server.openSessionOverlay(target, window: nil,
                                             options: options(page: .file(path: "/tmp/p.html", grantRoot: nil)))

        XCTAssertEqual(program, ControlResponse(ok: false, error: OverlayVisibilityError.hidden))
        XCTAssertEqual(page, ControlResponse(ok: false, error: OverlayVisibilityError.hidden))
        XCTAssertEqual(session.overlayCommand, "true")
    }

    func testOpeningIntoAHiddenPaneSlotIsRefusedByNameWhileTheOtherSlotsStayOpen() throws {
        let (store, session) = try addSession()
        let target = session.id.uuidString
        XCTAssertTrue(server.openSessionOverlay(target, window: nil, options: options(pane: .left)).ok)
        store.setOverlaysHidden(session.id, pane: .left, hidden: true)

        let pane = server.openSessionOverlay(target, window: nil, options: options(pane: .left))
        let sessionWide = server.openSessionOverlay(target, window: nil, options: options())

        XCTAssertEqual(pane, ControlResponse(ok: false, error: OverlayVisibilityError.hidden))
        XCTAssertTrue(sessionWide.ok, sessionWide.error ?? "")
    }

    func testAHudCannotOpenOverAHiddenProgramButAHiddenPaneOverlayDoesNotBlockIt() throws {
        let (store, session) = try addSession()
        let target = session.id.uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: ControlServer.bodyFile(for: session.id)) }
        XCTAssertTrue(server.openSessionOverlay(target, window: nil, options: options(pane: .left)).ok)
        store.setOverlaysHidden(session.id, pane: .left, hidden: true)

        let overPane = server.openHud(target, window: nil, spec: HudSpec(message: "building"))
        XCTAssertTrue(overPane.ok, overPane.error ?? "")
        store.closeOverlay(session.id)

        XCTAssertTrue(server.openSessionOverlay(target, window: nil, options: options()).ok)
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)
        let overProgram = server.openHud(target, window: nil, spec: HudSpec(message: "building"))

        XCTAssertEqual(overProgram, ControlResponse(ok: false, error: OverlayVisibilityError.hidden))
        XCTAssertNil(session.hudSpec)
    }

    func testAPresentedSessionStillRefusesAnOpenIntoItsHiddenLocalSlot() throws {
        let (store, session) = try addSession()
        let target = session.id.uuidString
        XCTAssertTrue(server.openSessionOverlay(target, window: nil, options: options()).ok)
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: session.paneIdentity)
        _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:follower:1")), pane: session.paneIdentity)
        addTeardownBlock { ZmxLeadBook.shared.forget(pane: session.paneIdentity) }
        server.attachPresentationHub()
        let sink = PresenterSink()
        let id = try server.presentationHub.subscribe(
            session: session.id, hello: PresentationHello(version: 1, kinds: [], mode: .presenter), sink: sink
        ) { PresentationSnapshot(status: nil, hud: nil) }
        server.presentationHub.receive(PresentationFrame(gen: sink.generation, rev: 0, body: .presenterAcquire), from: id)

        let response = server.openSessionOverlay(target, window: nil, options: options())

        XCTAssertEqual(response, ControlResponse(ok: false, error: OverlayVisibilityError.hidden))
        XCTAssertNil(session.remoteOverlays.slot(nil))
    }
}
