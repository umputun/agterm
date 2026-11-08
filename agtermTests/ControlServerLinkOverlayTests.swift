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

    func testAMarkdownFileOpensOverTheControlPathAndAnUnreadableOneOpensNothing() throws {
        let (store, session) = try addSession()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let doc = stateDir.appendingPathComponent("doc.md")
        try Data("# Doc\n".utf8).write(to: doc)
        let missing = stateDir.appendingPathComponent("missing.md").path
        let fifo = stateDir.appendingPathComponent("pipe.md").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let big = stateDir.appendingPathComponent("big.md")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(MarkdownPage.maxBytes + 1))
        try handle.close()
        let open = { (path: String) in
            self.server.openSessionOverlay(session.id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
                command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, page: .markdown(path: path)))
        }

        XCTAssertEqual(open(missing), ControlResponse(ok: false, error: "session.overlay.open: \(MarkdownProbe.Failure.unreadable(missing))"))
        XCTAssertEqual(open(fifo), ControlResponse(ok: false, error: "session.overlay.open: \(MarkdownProbe.Failure.unreadable(fifo))"))
        XCTAssertEqual(open(big.path), ControlResponse(ok: false, error: "session.overlay.open: \(MarkdownProbe.Failure.tooLarge(big.path))"))
        XCTAssertNil(session.htmlOverlay)

        XCTAssertTrue(open(doc.path).ok)
        XCTAssertEqual(session.htmlOverlay?.source, .markdown(path: doc.path))
        store.closeOverlay(session.id)
    }

    func testAMarkdownFileOpenedWithNavigationOverTheControlPathGetsItsLinkGrantOrNoNavigation() throws {
        let (store, session) = try addSession()
        let doc = try writeMarkdown("doc.md")
        let notes = stateDir.appendingPathComponent("notes.txt")
        try Data("# notes\n".utf8).write(to: notes)
        let disguised = stateDir.appendingPathComponent("disguised.md")
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: notes)
        let open = { (path: String, navigation: Bool) in
            self.server.openSessionOverlay(session.id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
                command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, page: .markdown(path: path),
                navigation: navigation))
        }

        XCTAssertTrue(open(doc.path, true).ok)
        XCTAssertEqual(session.htmlOverlay?.navigation, true)
        XCTAssertEqual(session.htmlOverlay?.markdownLinks, MarkdownPage.linkGrant(for: doc.path))
        XCTAssertNotNil(session.htmlOverlay?.markdownLinks)
        store.closeOverlay(session.id)

        XCTAssertTrue(open(doc.path, false).ok)
        XCTAssertEqual(session.htmlOverlay?.navigation, false)
        XCTAssertNil(session.htmlOverlay?.markdownLinks)
        store.closeOverlay(session.id)

        XCTAssertTrue(open(disguised.path, true).ok)
        XCTAssertEqual(session.htmlOverlay?.navigation, false)
        XCTAssertNil(session.htmlOverlay?.markdownLinks)
        store.closeOverlay(session.id)
    }

    func testATextFileOpensOverTheControlPathAndAnUnreadableOrBinaryOneOpensNothing() throws {
        let (store, session) = try addSession()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let source = stateDir.appendingPathComponent("main.go")
        try Data("package main\n".utf8).write(to: source)
        let missing = stateDir.appendingPathComponent("missing.go").path
        let fifo = stateDir.appendingPathComponent("pipe.log").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let big = stateDir.appendingPathComponent("big.log")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(TextPage.maxBytes + 1))
        try handle.close()
        let binary = stateDir.appendingPathComponent("bin.txt")
        try Data([0x61, 0x00, 0x62]).write(to: binary)
        let open = { (path: String) in
            self.server.openSessionOverlay(session.id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
                command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, page: .text(path: path, line: 4)))
        }

        XCTAssertEqual(open(missing), ControlResponse(ok: false, error: "session.overlay.open: \(TextProbe.Failure.unreadable(missing))"))
        XCTAssertEqual(open(fifo), ControlResponse(ok: false, error: "session.overlay.open: \(TextProbe.Failure.unreadable(fifo))"))
        XCTAssertEqual(open(big.path), ControlResponse(ok: false, error: "session.overlay.open: \(TextProbe.Failure.tooLarge(big.path))"))
        XCTAssertEqual(open(binary.path), ControlResponse(ok: false, error: "session.overlay.open: \(TextProbe.Failure.notText(binary.path))"))
        XCTAssertNil(session.htmlOverlay)

        XCTAssertTrue(open(source.path).ok)
        XCTAssertEqual(session.htmlOverlay?.source, .text(path: source.path, line: 4))
        store.closeOverlay(session.id)
    }

    func testAClickedMarkdownFileOpensAtItsSizeWithoutSelectingIt() async throws {
        let (store, session) = try addSession()
        let other = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory()))
        store.selectSession(other.id)
        let doc = try writeMarkdown("doc.md")

        let shown = await openMarkdown(doc, session: session.id, sizePercent: 75)

        XCTAssertTrue(shown)
        XCTAssertEqual(session.htmlOverlay?.source, .markdown(path: doc.path))
        XCTAssertEqual(session.overlaySizePercent, 75)
        XCTAssertEqual(store.selectedSessionID, other.id)
        store.closeOverlay(session.id)
    }

    func testAClickedMarkdownFileOpensWithNavigationAndItsLinkGrant() async throws {
        let (store, session) = try addSession()
        let doc = try writeMarkdown("doc.md")

        let shown = await openMarkdown(doc, session: session.id, sizePercent: nil)

        XCTAssertTrue(shown)
        let canonical = doc.resolvingSymlinksInPath().path
        XCTAssertEqual(session.htmlOverlay?.navigation, true)
        XCTAssertEqual(session.htmlOverlay?.markdownLinks,
                       MarkdownLinkGrant(path: canonical, root: URL(fileURLWithPath: canonical).deletingLastPathComponent().path))
        store.closeOverlay(session.id)
    }

    func testAClickedMarkdownFileIsRefusedUnderAHudAZoomABusySlotOrWhenUnreadable() async throws {
        let (store, session) = try addSession()
        let doc = try writeMarkdown("doc.md")

        let missing = await openMarkdown(stateDir.appendingPathComponent("missing.md"), session: session.id, sizePercent: nil)
        XCTAssertFalse(missing)
        XCTAssertTrue(store.openOverlay(session.id, command: "/bin/cat", sizePercent: nil))
        let busy = await openMarkdown(doc, session: session.id, sizePercent: nil)
        XCTAssertFalse(busy)
        store.closeOverlay(session.id)
        XCTAssertTrue(store.openHud(session.id, command: "/bin/cat", spec: HudSpec(message: "recap"), file: "/tmp/hud",
                                    size: HudPanelSize(widthPercent: 40, heightPercent: 20)))
        let underHud = await openMarkdown(doc, session: session.id, sizePercent: nil)
        XCTAssertFalse(underHud)
        XCTAssertTrue(session.hudActive)
        store.closeOverlay(session.id)
        let windowID = try XCTUnwrap(library.windowID(forSession: session.id))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        zoom.set(.on, target: .session(session.id, .primary))
        let zoomed = await openMarkdown(doc, session: session.id, sizePercent: nil)
        XCTAssertFalse(zoomed)
        XCTAssertEqual(zoom.target, .session(session.id, .primary))
        XCTAssertNil(session.htmlOverlay)
    }

    func testAClickedHtmlFileOpensAsADocumentAndAnUnreadableOneOpensNothing() async throws {
        let (store, session) = try addSession()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let page = stateDir.appendingPathComponent("pr.html")
        try Data("<title>pr</title>".utf8).write(to: page)
        let binary = stateDir.appendingPathComponent("blob.html")
        try Data([0x3C, 0x00]).write(to: binary)

        let missing = await openDocument(stateDir.appendingPathComponent("missing.html"), session: session.id, sizePercent: nil)
        let unreadable = await openDocument(binary, session: session.id, sizePercent: nil)
        XCTAssertFalse(missing)
        XCTAssertFalse(unreadable)
        XCTAssertNil(session.htmlOverlay)

        let shown = await openDocument(page, session: session.id, sizePercent: 75)
        XCTAssertTrue(shown)
        XCTAssertEqual(session.htmlOverlay?.source, .document(path: page.path))
        XCTAssertEqual(session.htmlOverlay?.javascript, false)
        XCTAssertEqual(session.htmlOverlay?.clicked, true)
        XCTAssertEqual(session.overlaySizePercent, 75)
        store.closeOverlay(session.id)
    }

    func testAClickedLogOpensAsAFollowingLogPageAndItsLocationAsTheStaticPage() async throws {
        let (store, session) = try addSession()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let log = stateDir.appendingPathComponent("app.out")
        try Data("one\ntwo\nthree\n".utf8).write(to: log)

        let plain = await openText(log, line: nil, session: session.id, sizePercent: nil)
        XCTAssertTrue(plain)
        XCTAssertEqual(session.htmlOverlay?.textLog, TextLog(tail: TextPage.defaultTail, follow: true))
        XCTAssertEqual(session.htmlOverlay?.clicked, true)
        store.closeOverlay(session.id)

        let located = await openText(log, line: 2, session: session.id, sizePercent: nil)
        XCTAssertTrue(located)
        XCTAssertEqual(session.htmlOverlay?.source, .text(path: log.path, line: 2))
        XCTAssertNil(session.htmlOverlay?.textLog)
        store.closeOverlay(session.id)
    }

    func testAClickedLogOverTheWholeFileCapOpensWhileOtherTextIsRefused() async throws {
        let (store, session) = try addSession()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let line = String(repeating: "x", count: 99) + "\n"
        let body = Data(String(repeating: line, count: TextPage.maxBytes / 100 + 10).utf8)
        let log = stateDir.appendingPathComponent("big.log")
        let text = stateDir.appendingPathComponent("big.txt")
        try body.write(to: log)
        try body.write(to: text)

        let refused = await openText(text, line: nil, session: session.id, sizePercent: nil)
        XCTAssertFalse(refused)
        let opened = await openText(log, line: nil, session: session.id, sizePercent: nil)
        XCTAssertTrue(opened)
        XCTAssertNotNil(session.htmlOverlay?.textLog)
        store.closeOverlay(session.id)
    }

    func testAClickedLogInAPresentedSessionGoesToTheViewerAsTheStaticPage() async throws {
        let (_, session) = try addSession()
        try present(session)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let log = stateDir.appendingPathComponent("app.log")
        try Data("one\n".utf8).write(to: log)

        let opened = await openText(log, line: nil, session: session.id, sizePercent: nil)

        XCTAssertTrue(opened)
        XCTAssertNil(session.htmlOverlay)
        XCTAssertNotNil(session.remoteOverlays.slot(nil)?.page)
    }

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

    private func present(_ session: Session) throws {
        for pane in [session.paneIdentity] + [session.splitPaneIdentity].compactMap({ $0 }) {
            ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: pane)
            _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:follower:1")), pane: pane)
        }
        server.attachPresentationHub()
        let sink = PresenterSink()
        let kinds = PresentationHub.pageKinds + [PresentationHub.pageContentKind]
        let id = try server.presentationHub.subscribe(
            session: session.id, hello: PresentationHello(version: 1, kinds: kinds, mode: .presenter), sink: sink
        ) { PresentationSnapshot(status: nil, hud: nil) }
        server.presentationHub.receive(PresentationFrame(gen: sink.generation, rev: 0, body: .presenterAcquire), from: id)
    }

    func testAClickedTextFileOpensAtItsLineAndSizeWithoutSelectingIt() async throws {
        let (store, session) = try addSession()
        let other = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory()))
        store.selectSession(other.id)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let source = stateDir.appendingPathComponent("main.go")
        try Data("package main\n".utf8).write(to: source)

        let shown = await openText(source, line: 12, session: session.id, sizePercent: 75)

        XCTAssertTrue(shown)
        XCTAssertEqual(session.htmlOverlay?.source, .text(path: source.path, line: 12))
        XCTAssertEqual(session.overlaySizePercent, 75)
        XCTAssertEqual(store.selectedSessionID, other.id)
        store.closeOverlay(session.id)
    }

    func testAClickedTextFileIsRefusedUnderAHudAZoomABusySlotOrWhenUnreadableOrBinary() async throws {
        let (store, session) = try addSession()
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let source = stateDir.appendingPathComponent("main.go")
        try Data("package main\n".utf8).write(to: source)
        let binary = stateDir.appendingPathComponent("bin.txt")
        try Data([0x61, 0x00, 0x62]).write(to: binary)

        let missing = await openText(stateDir.appendingPathComponent("missing.go"), line: nil, session: session.id, sizePercent: nil)
        XCTAssertFalse(missing)
        let notText = await openText(binary, line: nil, session: session.id, sizePercent: nil)
        XCTAssertFalse(notText)
        XCTAssertTrue(store.openOverlay(session.id, command: "/bin/cat", sizePercent: nil))
        let busy = await openText(source, line: nil, session: session.id, sizePercent: nil)
        XCTAssertFalse(busy)
        store.closeOverlay(session.id)
        XCTAssertTrue(store.openHud(session.id, command: "/bin/cat", spec: HudSpec(message: "recap"), file: "/tmp/hud",
                                    size: HudPanelSize(widthPercent: 40, heightPercent: 20)))
        let underHud = await openText(source, line: nil, session: session.id, sizePercent: nil)
        XCTAssertFalse(underHud)
        XCTAssertTrue(session.hudActive)
        store.closeOverlay(session.id)
        let windowID = try XCTUnwrap(library.windowID(forSession: session.id))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        zoom.set(.on, target: .session(session.id, .primary))
        let zoomed = await openText(source, line: nil, session: session.id, sizePercent: nil)
        XCTAssertFalse(zoomed)
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

    func testALinkReplacesAHiddenPageAnEarlierClickOpenedAndShowsIt() async throws {
        let (store, session) = try addSession()
        let before = useBrowserProfile()
        let first = try XCTUnwrap(URL(string: "http://127.0.0.1:1/pr/1"))
        let second = try XCTUnwrap(URL(string: "http://127.0.0.1:1/pr/2"))
        XCTAssertTrue(server.openLinkOverlay(first, session: session.id, sizePercent: nil))
        let old = try XCTUnwrap(session.htmlOverlay)
        XCTAssertTrue(old.clicked)
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)

        XCTAssertTrue(server.openLinkOverlay(second, session: session.id, sizePercent: 75))

        let page = try XCTUnwrap(session.htmlOverlay)
        XCTAssertNotEqual(page.id, old.id)
        XCTAssertEqual(page.source, .url(second))
        XCTAssertTrue(page.clicked)
        XCTAssertFalse(session.overlayHidden)
        XCTAssertEqual(session.overlaySizePercent, 75)
        XCTAssertEqual(HtmlPageOutcomes.shared.outcome(for: old.id)?.outcome, .dismissed)
        store.closeOverlay(session.id)
        try await TestBrowserStore.remove(BrowserProfile(directory: stateDir))
        HtmlOverlayRegistry.shared.profile = before
    }

    func testALinkLeavesAHiddenPageNoClickOpened() async throws {
        let (store, session) = try addSession()
        let before = useBrowserProfile()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/dashboard"))
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                                       page: .url(url), navigation: true, javascript: true, persistent: true,
                                                       browse: true)
        XCTAssertTrue(server.openSessionOverlay(session.id.uuidString, window: nil, options: options).ok)
        let kept = try XCTUnwrap(session.htmlOverlay)
        XCTAssertFalse(kept.clicked)
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)

        XCTAssertFalse(server.openLinkOverlay(try XCTUnwrap(URL(string: "http://127.0.0.1:1/pr/1")), session: session.id,
                                              sizePercent: nil))

        XCTAssertEqual(session.htmlOverlay?.id, kept.id)
        XCTAssertTrue(session.overlayHidden)
        store.closeOverlay(session.id)
        try await TestBrowserStore.remove(BrowserProfile(directory: stateDir))
        HtmlOverlayRegistry.shared.profile = before
    }

    func testALinkLeavesAHiddenClickedPageWhenTheSavedStoreIsUnusable() async throws {
        let (store, session) = try addSession()
        let doc = try writeMarkdown("doc.md")
        let opened = await openMarkdown(doc, session: session.id, sizePercent: nil)
        XCTAssertTrue(opened)
        let kept = try XCTUnwrap(session.htmlOverlay)
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)
        let before = HtmlOverlayRegistry.shared.profile
        defer { HtmlOverlayRegistry.shared.profile = before }
        HtmlOverlayRegistry.shared.profile = nil

        XCTAssertFalse(server.openLinkOverlay(try XCTUnwrap(URL(string: "http://127.0.0.1:1/")), session: session.id,
                                              sizePercent: nil))

        XCTAssertEqual(session.htmlOverlay?.id, kept.id)
        XCTAssertTrue(session.overlayHidden)
        store.closeOverlay(session.id)
    }

    func testEachClickedFileKindReplacesAHiddenClickedPage() async throws {
        let (store, session) = try addSession()
        let doc = try writeMarkdown("doc.md")
        let source = stateDir.appendingPathComponent("main.go")
        try Data("package main\n".utf8).write(to: source)
        let picture = URL(fileURLWithPath: try writePNG(width: 40, height: 30))
        let markdown = await openMarkdown(doc, session: session.id, sizePercent: nil)
        XCTAssertTrue(markdown)

        store.setOverlaysHidden(session.id, pane: nil, hidden: true)
        let text = await openText(source, line: 3, session: session.id, sizePercent: nil)
        XCTAssertTrue(text)
        XCTAssertEqual(session.htmlOverlay?.source, .text(path: source.path, line: 3))
        XCTAssertEqual(session.htmlOverlay?.clicked, true)
        XCTAssertFalse(session.overlayHidden)

        store.setOverlaysHidden(session.id, pane: nil, hidden: true)
        let image = await openImage(picture, session: session.id)
        XCTAssertTrue(image)
        XCTAssertEqual(session.htmlOverlay?.source, .image(path: picture.path))
        XCTAssertEqual(session.htmlOverlay?.clicked, true)
        XCTAssertFalse(session.overlayHidden)

        store.setOverlaysHidden(session.id, pane: nil, hidden: true)
        let again = await openMarkdown(doc, session: session.id, sizePercent: nil)
        XCTAssertTrue(again)
        XCTAssertEqual(session.htmlOverlay?.source, .markdown(path: doc.path))
        XCTAssertFalse(session.overlayHidden)
        store.closeOverlay(session.id)
    }

    func testAClickedFileThatCannotOpenLeavesTheHiddenClickedPage() async throws {
        let (store, session) = try addSession()
        let doc = try writeMarkdown("doc.md")
        let opened = await openMarkdown(doc, session: session.id, sizePercent: nil)
        XCTAssertTrue(opened)
        let kept = try XCTUnwrap(session.htmlOverlay)
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)

        let missing = await openMarkdown(stateDir.appendingPathComponent("missing.md"), session: session.id, sizePercent: nil)
        let binary = stateDir.appendingPathComponent("blob.txt")
        try Data([0x00, 0x01]).write(to: binary)
        let unreadable = await openText(binary, line: nil, session: session.id, sizePercent: nil)

        XCTAssertFalse(missing)
        XCTAssertFalse(unreadable)
        XCTAssertEqual(session.htmlOverlay?.id, kept.id)
        XCTAssertTrue(session.overlayHidden)
        store.closeOverlay(session.id)
    }

    private func openText(_ url: URL, line: Int?, session id: UUID, sizePercent: Int?) async -> Bool {
        let link = LinkPolicy.TextLink(url: url, line: line, session: id, sizePercent: sizePercent)
        return await withCheckedContinuation { continuation in
            server.openTextLink(link) { continuation.resume(returning: $0) }
        }
    }

    private func openDocument(_ url: URL, session id: UUID, sizePercent: Int?) async -> Bool {
        await withCheckedContinuation { continuation in
            server.openDocumentLink(url, session: id, sizePercent: sizePercent) { continuation.resume(returning: $0) }
        }
    }

    private func openMarkdown(_ url: URL, session id: UUID, sizePercent: Int?) async -> Bool {
        await withCheckedContinuation { continuation in
            server.openMarkdownLink(url, session: id, sizePercent: sizePercent) { continuation.resume(returning: $0) }
        }
    }

    private func writeMarkdown(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let url = stateDir.appendingPathComponent(name)
        try Data("# Doc\n".utf8).write(to: url)
        return url
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
