import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerLinkOverlayTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-link-overlay-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            server = ControlServer(
                library: library,
                actions: AppActions(library: library),
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private func useBrowserProfile() -> BrowserProfile? {
        let before = HtmlOverlayRegistry.shared.profile
        HtmlOverlayRegistry.shared.profile = BrowserProfile(directory: stateDir)
        return before
    }

    func testALinkOpensAsAFullBrowsingPageOnItsSessionWithoutSelectingIt() async throws {
        let (store, session) = try addSession()
        let (_, other) = try addSession()
        store.selectSession(other.id)
        let before = useBrowserProfile()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/pr/1"))

        XCTAssertTrue(server.openLinkOverlay(url, session: session.id))

        let page = try XCTUnwrap(session.htmlOverlay)
        XCTAssertEqual(page.source, .url(url))
        XCTAssertTrue(page.browse && page.javascript && page.navigation && page.persistent)
        XCTAssertNil(session.overlaySizePercent)
        XCTAssertEqual(store.selectedSessionID, other.id)
        store.closeOverlay(session.id)
        try await TestBrowserStore.remove(BrowserProfile(directory: stateDir))
        HtmlOverlayRegistry.shared.profile = before
    }

    func testALinkLeavesAHudUpAndOpensNoPage() throws {
        let (store, session) = try addSession()
        let before = useBrowserProfile()
        defer { HtmlOverlayRegistry.shared.profile = before }
        XCTAssertTrue(store.openHud(session.id, command: "/bin/cat", spec: HudSpec(message: "recap"), file: "/tmp/hud",
                                    size: HudPanelSize(widthPercent: 40, heightPercent: 20)))

        XCTAssertFalse(server.openLinkOverlay(try XCTUnwrap(URL(string: "http://127.0.0.1:1/")), session: session.id))

        XCTAssertTrue(session.hudActive)
        XCTAssertNil(session.htmlOverlay)
        store.closeOverlay(session.id)
    }

    func testALinkIsRefusedWhileAProgramHoldsTheSlot() throws {
        let (store, session) = try addSession()
        let before = useBrowserProfile()
        defer { HtmlOverlayRegistry.shared.profile = before }
        XCTAssertTrue(store.openOverlay(session.id, command: "/bin/cat"))

        XCTAssertFalse(server.openLinkOverlay(try XCTUnwrap(URL(string: "http://127.0.0.1:1/")), session: session.id))

        XCTAssertTrue(session.programOverlayActive)
        store.closeOverlay(session.id)
    }

    func testALinkInAZoomedWindowOpensNoPageAndLeavesZoomSet() throws {
        let (_, session) = try addSession()
        let before = useBrowserProfile()
        defer { HtmlOverlayRegistry.shared.profile = before }
        let windowID = try XCTUnwrap(library.windowID(forSession: session.id))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        zoom.set(.on, target: .session(session.id, .primary))

        XCTAssertFalse(server.openLinkOverlay(try XCTUnwrap(URL(string: "http://127.0.0.1:1/")), session: session.id))

        XCTAssertNil(session.htmlOverlay)
        XCTAssertEqual(zoom.target, .session(session.id, .primary))
    }

    func testALinkIsRefusedWithoutAUsableSavedStoreOrAKnownSession() throws {
        let (_, session) = try addSession()
        let before = HtmlOverlayRegistry.shared.profile
        defer { HtmlOverlayRegistry.shared.profile = before }
        HtmlOverlayRegistry.shared.profile = nil
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/"))

        XCTAssertFalse(server.openLinkOverlay(url, session: session.id))
        XCTAssertNil(session.htmlOverlay)
        XCTAssertFalse(server.openLinkOverlay(url, session: UUID()))
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory())))
    }
}
