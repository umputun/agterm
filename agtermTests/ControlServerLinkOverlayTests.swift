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
            server.stop()
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

        XCTAssertTrue(server.openLinkOverlay(url, session: session.id, sizePercent: nil))

        let page = try XCTUnwrap(session.htmlOverlay)
        XCTAssertEqual(page.source, .url(url))
        XCTAssertTrue(page.browse && page.javascript && page.navigation && page.persistent)
        XCTAssertNil(session.overlaySizePercent)
        XCTAssertEqual(store.selectedSessionID, other.id)
        store.closeOverlay(session.id)
        try await TestBrowserStore.remove(BrowserProfile(directory: stateDir))
        HtmlOverlayRegistry.shared.profile = before
    }

    func testALinkOpensAtTheSizeItsModeNames() async throws {
        let (store, session) = try addSession()
        let before = useBrowserProfile()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/pr/1"))

        XCTAssertTrue(server.openLinkOverlay(url, session: session.id, sizePercent: 75))

        XCTAssertEqual(session.htmlOverlay?.source, .url(url))
        XCTAssertEqual(session.overlaySizePercent, 75)
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

        XCTAssertFalse(server.openLinkOverlay(try XCTUnwrap(URL(string: "http://127.0.0.1:1/")), session: session.id, sizePercent: nil))

        XCTAssertTrue(session.hudActive)
        XCTAssertNil(session.htmlOverlay)
        store.closeOverlay(session.id)
    }

    func testALinkIsRefusedWhileAProgramHoldsTheSlot() throws {
        let (store, session) = try addSession()
        let before = useBrowserProfile()
        defer { HtmlOverlayRegistry.shared.profile = before }
        XCTAssertTrue(store.openOverlay(session.id, command: "/bin/cat"))

        XCTAssertFalse(server.openLinkOverlay(try XCTUnwrap(URL(string: "http://127.0.0.1:1/")), session: session.id, sizePercent: nil))

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

        XCTAssertFalse(server.openLinkOverlay(try XCTUnwrap(URL(string: "http://127.0.0.1:1/")), session: session.id, sizePercent: nil))

        XCTAssertNil(session.htmlOverlay)
        XCTAssertEqual(zoom.target, .session(session.id, .primary))
    }

    func testALinkIsRefusedWithoutAUsableSavedStoreOrAKnownSession() throws {
        let (_, session) = try addSession()
        let before = HtmlOverlayRegistry.shared.profile
        defer { HtmlOverlayRegistry.shared.profile = before }
        HtmlOverlayRegistry.shared.profile = nil
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/"))

        XCTAssertFalse(server.openLinkOverlay(url, session: session.id, sizePercent: nil))
        XCTAssertNil(session.htmlOverlay)
        XCTAssertFalse(server.openLinkOverlay(url, session: UUID(), sizePercent: nil))
    }

    func testAnImageOpensSizedToThePictureWithoutSelectingIt() async throws {
        let (store, session) = try addSession()
        let (_, other) = try addSession()
        store.selectSession(other.id)
        let path = try writePNG(width: 2000, height: 1000)
        let windowID = try XCTUnwrap(library.windowID(forSession: session.id))
        let window = TripleDensityWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(windowID, window: window)
        defer { WindowRegistry.shared.unregister(windowID) }

        let shown = await openImage(URL(fileURLWithPath: path), session: session.id)

        XCTAssertTrue(shown)
        XCTAssertEqual(session.htmlOverlay?.source, .image(path: path))
        XCTAssertEqual(session.overlaySizePercent, ImagePage.basePercent)
        let natural = ImagePage.natural(pixelWidth: 2000, pixelHeight: 1000, orientation: 1, scale: 3)
        XCTAssertEqual(session.overlayPoints, ImagePage.points(natural: natural, zoom: HtmlOverlayRegistry.shared.zoom,
                                                               bounds: session.hudPaneFrames.detail))
        XCTAssertEqual(store.selectedSessionID, other.id)
        store.closeOverlay(session.id)
    }

    func testAnImageOpenedWithASizeKeepsIt() throws {
        let (store, session) = try addSession()
        let path = try writePNG(width: 2000, height: 1000)
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: 60,
                                                       backgroundColor: nil, page: .image(path: path))

        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil, options: options).ok)

        XCTAssertEqual(session.overlaySizePercent, 60)
        XCTAssertTrue(session.overlayPoints.isEmpty)
        store.closeOverlay(session.id)
    }

    func testAMissingOrNonImageFileIsRefusedAndOpensNothing() async throws {
        let (_, session) = try addSession()
        let fake = stateDir.appendingPathComponent("fake.png")
        try Data("not a picture".utf8).write(to: fake)
        let missing = stateDir.appendingPathComponent("missing.png")

        let fakeShown = await openImage(fake, session: session.id)
        let missingShown = await openImage(missing, session: session.id)
        XCTAssertFalse(fakeShown)
        XCTAssertFalse(missingShown)
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                       backgroundColor: nil, page: .image(path: missing.path))
        XCTAssertEqual(server.openSessionOverlay(session.id.uuidString, window: nil, options: options),
                       ControlResponse(ok: false, error: "session.overlay.open: unreadable image: \(missing.path)"))
        XCTAssertNil(session.htmlOverlay)
    }

    func testAnImageLeavesAHudUpAndOpensNoPage() async throws {
        let (store, session) = try addSession()
        let path = try writePNG(width: 100, height: 100)
        XCTAssertTrue(store.openHud(session.id, command: "/bin/cat", spec: HudSpec(message: "recap"), file: "/tmp/hud",
                                    size: HudPanelSize(widthPercent: 40, heightPercent: 20)))

        let shown = await openImage(URL(fileURLWithPath: path), session: session.id)

        XCTAssertFalse(shown)
        XCTAssertTrue(session.hudActive)
        store.closeOverlay(session.id)
    }

    private func openImage(_ url: URL, session id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            server.openImageLink(url, session: id) { continuation.resume(returning: $0) }
        }
    }

    private final class TripleDensityWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 3 }
    }

    private func writePNG(width: Int, height: Int) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let url = stateDir.appendingPathComponent("shot-\(width)x\(height).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory())))
    }
}
