import WebKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemotePageTests: XCTestCase {
    @MainActor
    private final class Transport: RemotePresentationTransport {
        final class Link: RemotePresentationLink {
            var sent: [PresentationFrame.Body] = []
            func send(_ line: Data) {
                if let frame = try? PresentationCodec.decode(line.dropLast()) { sent.append(frame.body) }
            }
            func stop() {}
        }

        var links: [Link] = []
        var deliver: [(Data) -> Void] = []
        private var rev = 0

        func open(_: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose _: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            deliver.append(onLine)
            let link = Link()
            links.append(link)
            return link
        }

        func feed(_ body: PresentationFrame.Body) throws {
            rev += 1
            let line = try PresentationCodec.encode(PresentationFrame(gen: 3, rev: rev, body: body)).dropLast()
            deliver.last?(Data(line))
        }

        var sent: [PresentationFrame.Body] { links.last?.sent ?? [] }
    }

    private final class Browser: HtmlBrowser {
        var opened: [URL] = []
        func confirm(_: URL, over _: NSView, _ done: @escaping (Bool) -> Void) -> (() -> Void)? {
            done(false)
            return nil
        }
        func open(_ url: URL) -> Bool {
            opened.append(url)
            return true
        }
    }

    private struct Fixture {
        let server: ControlServer
        let store: AppStore
        let session: Session
        let transport: Transport
        let launcher: FakePageLauncher
    }

    private static let origin = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private var stateDir: URL!
    private var servers: [ControlServer] = []
    private var launchers: [FakePageLauncher] = []
    private var windows: [NSWindow] = []
    private var savedBrowser: (any HtmlBrowser)?

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-page-\(UUID().uuidString)", isDirectory: true)
        savedBrowser = HtmlOverlayRegistry.shared.browser
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for server in servers {
            for store in server.library.openIDs().compactMap({ server.library.store(for: $0) }) {
                for session in store.workspaces.flatMap(\.sessions) { store.closeSession(session.id) }
            }
            server.stop()
        }
        servers.removeAll()
        for launcher in launchers { launcher.closeAll() }
        launchers.removeAll()
        if let savedBrowser { HtmlOverlayRegistry.shared.browser = savedBrowser }
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func fixture(files: [String: (String, Data)] = [:], reply: String? = #"{"ok":true,"result":{}}"#) throws -> Fixture {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: "/tmp/agterm-rpg-\(UUID().uuidString.prefix(8)).sock"
        )
        servers.append(server)
        server.attachPresentationHub()
        let launcher = FakePageLauncher(files: files)
        launcher.reply = reply
        launchers.append(launcher)
        server.pageLauncher = launcher
        let transport = Transport()
        server.remoteTransport = transport
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [:], presentationVersion: 1),
                         forSession: session.id)
        server.startRemotePresentation(for: session)
        try transport.feed(.hello(PresentationHello(version: 1, kinds: PresentationHub.supportedKinds, mode: .presenter)))
        try transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)))
        return Fixture(server: server, store: store, session: session, transport: transport, launcher: launcher)
    }

    private func page(_ source: PresentationPageSource, javascript: Bool = true) -> PresentationPage {
        PresentationPage(page: Self.origin.uuidString, token: "tok-1", source: source, identity: "index.html",
                         chromeless: false, javascript: javascript, navigation: true, browse: false, persistent: false,
                         backgroundColor: nil, pane: nil, sizePercent: nil, follow: false)
    }

    private func html(_ text: String) -> (String, Data) { ("text/html", Data(text.utf8)) }

    private func present(_ fix: Fixture, _ page: PresentationPage) throws -> HtmlOverlayPage {
        try fix.transport.feed(.pageRequest(page))
        let local = try XCTUnwrap(fix.session.htmlOverlay?.id)
        return try XCTUnwrap(HtmlOverlayRegistry.shared.existing(local))
    }

    private func closedNotices(_ fix: Fixture) -> Int {
        fix.transport.sent.filter { $0 == .pageClosed(PresentationPageChange(page: Self.origin.uuidString)) }.count
    }

    private func states(_ fix: Fixture) -> [PresentationPageState] {
        fix.transport.sent.compactMap { if case .pageState(let state) = $0 { state } else { nil } }
    }

    func testAFileReplicaLoadsItsPageAndAnAssetThroughItsChannel() async throws {
        let fix = try fixture(files: [
            "/docs/index.html": html(#"<title>R</title><link rel="stylesheet" href="style.css"><p id="p">x</p>"#),
            "/docs/style.css": ("text/css", Data("#p { color: rgb(1, 2, 3); }".utf8)),
        ])

        let shown = try present(fix, page(.file(path: "/docs/index.html", grantRoot: "/docs")))

        try await waitForJS(shown.webView, "getComputedStyle(document.getElementById('p')).color", equals: "rgb(1, 2, 3)")
        try await waitFor("the logical path is read back") { fix.session.htmlOverlay?.current?.page == "/docs/index.html" }
        XCTAssertEqual(fix.launcher.launches.count, 1)
        XCTAssertEqual(fix.launcher.launches.first?.prefix(2), ["ssh", "-T"])
        XCTAssertTrue(try XCTUnwrap(fix.launcher.launches.first?.last).contains("page-serve"))
        XCTAssertTrue(try XCTUnwrap(fix.launcher.launches.first?.last).contains("tok-1"))
        XCTAssertFalse(fix.transport.sent.contains { if case .pageRejected = $0 { true } else { false } })
        let node = try XCTUnwrap(fix.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == fix.session.id.uuidString }?
            .htmlOverlays?.first)
        XCTAssertEqual(node.replica, true)
        XCTAssertEqual(node.file, "/docs/index.html")
    }

    func testThePageScriptsBridgeRelaysToTheOriginAndKeepsUnknownFields() async throws {
        let fix = try fixture(files: [
            "/docs/index.html": html("<title>R</title><script>agterm.request('tree').then(r => document.title = r.extra.nested)</script>"),
        ], reply: #"{"ok":true,"result":{"extra":{"nested":"kept"}}}"#)

        let shown = try present(fix, page(.file(path: "/docs/index.html", grantRoot: nil)))

        try await waitFor("the reply reached the page") { shown.webView.title == "kept" }
        let bridged = fix.launcher.origins[0].received.compactMap { if case .bridge(_, let request) = $0 { request } else { nil } }
        XCTAssertEqual(bridged.count, 1)
        XCTAssertTrue(bridged[0].contains(#""cmd":"tree""#))
    }

    func testATaggedControlRelaysWithPageScriptOff() async throws {
        let fix = try fixture(files: [
            "/docs/index.html": html("""
                <title>T</title>
                <button type="button" id="b" data-agterm="session.select" data-agterm-target="3F2A" data-agterm-into="#out">go</button>
                <p id="out"></p>
                """),
        ], reply: #"{"ok":true,"result":{"text":"done"}}"#)
        let shown = try present(fix, page(.file(path: "/docs/index.html", grantRoot: nil), javascript: false))
        let window = try host(shown.webView)
        try await waitFor("loaded") { fix.session.htmlOverlay?.loadState == .loaded }

        try await click("b", in: shown.webView, window: window)

        try await waitForJS(shown.webView, "document.getElementById('out').textContent", equals: "done")
        let bridged = fix.launcher.origins[0].received.compactMap { if case .bridge(_, let request) = $0 { request } else { nil } }
        XCTAssertEqual(bridged.count, 1)
        XCTAssertTrue(bridged[0].contains("session.select") && bridged[0].contains("3F2A"))
    }

    func testAUrlReplicaNeedsNoHelperAndItsLocalCloseTellsTheOriginOnce() throws {
        let fix = try fixture()

        _ = try present(fix, page(.url("http://127.0.0.1:9/a")))
        XCTAssertEqual(fix.session.htmlOverlay?.source, .url(try XCTUnwrap(URL(string: "http://127.0.0.1:9/a"))))
        XCTAssertTrue(fix.launcher.launches.isEmpty)

        fix.store.closeOverlay(fix.session.id)
        fix.store.closeOverlay(fix.session.id)

        XCTAssertEqual(closedNotices(fix), 1)
    }

    func testFinderAndBrowserAreRefusedOnAFileReplicaButBrowserOpensAUrlReplica() throws {
        let browser = Browser()
        HtmlOverlayRegistry.shared.browser = browser
        let fix = try fixture(files: ["/docs/index.html": html("<p>x</p>")])
        let file = try present(fix, page(.file(path: "/docs/index.html", grantRoot: nil)))

        XCTAssertEqual(HtmlOverlayRegistry.shared.navigate(file.id, .finder), OverlayHtmlError.remoteFile)
        XCTAssertEqual(HtmlOverlayRegistry.shared.navigate(file.id, .browser), OverlayHtmlError.remoteFile)
        fix.store.closeOverlay(fix.session.id)

        let web = try present(fix, page(.url("http://127.0.0.1:9/a")))
        XCTAssertNil(HtmlOverlayRegistry.shared.navigate(web.id, .browser))
        XCTAssertEqual(browser.opened, [try XCTUnwrap(URL(string: "http://127.0.0.1:9/a"))])
    }

    func testASocketSubmitOnAReplicaIsRefusedAndTheReplicaStays() throws {
        let fix = try fixture()
        _ = try present(fix, page(.url("http://127.0.0.1:9/a")))

        let response = fix.server.submitSessionOverlay(fix.session.id.uuidString, window: nil, pane: nil, value: "x")

        XCTAssertEqual(response.error, OverlayHtmlError.replicaSubmit)
        XCTAssertTrue(fix.session.htmlOverlayActive)
        XCTAssertEqual(closedNotices(fix), 0)
    }

    func testEachTeardownTriggerEndsThePageOnce() throws {
        let fix = try fixture(files: ["/docs/index.html": html("<p>x</p>")])
        let file = PresentationPageSource.file(path: "/docs/index.html", grantRoot: nil)

        _ = try present(fix, page(file))
        try fix.transport.feed(.pageClose(PresentationPageChange(page: Self.origin.uuidString)))
        XCTAssertFalse(fix.session.overlayActive)
        XCTAssertEqual(closedNotices(fix), 1)
        XCTAssertTrue(fix.launcher.helpers[0].terminated)

        _ = try present(fix, page(file))
        fix.launcher.helpers[1].exit()
        XCTAssertFalse(fix.session.overlayActive)
        XCTAssertEqual(closedNotices(fix), 2)

        _ = try present(fix, page(file))
        fix.store.closeOverlay(fix.session.id)
        XCTAssertEqual(closedNotices(fix), 3)
        XCTAssertTrue(fix.launcher.helpers[2].terminated)

        _ = try present(fix, page(file))
        fix.store.setRemoteConnection(.failed("gone"), forSession: fix.session.id)
        XCTAssertFalse(fix.session.overlayActive)
        XCTAssertTrue(fix.launcher.helpers[3].terminated)
        XCTAssertTrue(fix.server.replicaPages.isEmpty)
    }

    func testAnOriginCommandIsAppliedAndReportedWithItsSequence() async throws {
        let fix = try fixture()
        _ = try present(fix, page(.url("http://127.0.0.1:9/a")))

        try fix.transport.feed(.pageCommand(PresentationPageCommand(page: Self.origin.uuidString, seq: 5, action: .hide)))

        XCTAssertTrue(fix.session.overlayHidden(nil))
        try await waitFor("the state is reported") { self.states(fix).last?.appliedSeq == 5 }
        XCTAssertEqual(states(fix).last?.hidden, true)
    }

    func testStateChangesInOneTurnAreReportedOnce() async throws {
        let fix = try fixture(files: ["/docs/index.html": html("<p>x</p>")])
        _ = try present(fix, page(.file(path: "/docs/index.html", grantRoot: nil)))
        let local = try XCTUnwrap(fix.session.htmlOverlay?.id)
        try await waitFor("the page loads") { fix.session.htmlOverlay?.loadState == .loaded && !self.states(fix).isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        let before = states(fix).count

        fix.store.setHtmlLoadState(local, state: .failed, error: "one")
        fix.store.setHtmlLoadState(local, state: .failed, error: "two")
        fix.store.setHtmlPage(local, HtmlPageInfo(page: "https://example.com/b", title: "B", canGoBack: true, canGoForward: false))

        try await waitFor("the change is reported") { self.states(fix).count > before }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(states(fix).count, before + 1)
        XCTAssertEqual(states(fix).last?.error, "two")
        XCTAssertEqual(states(fix).last?.title, "B")
    }

    private func host(_ view: NSView) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = try XCTUnwrap(window.contentView).bounds
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        windows.append(window)
        return window
    }

    private func click(_ id: String, in view: WKWebView, window: NSWindow) async throws {
        let value = try await view.evaluateJavaScript("""
            (() => { const r = document.getElementById('\(id)').getBoundingClientRect();
                     return [r.x + r.width / 2, r.y + r.height / 2] })()
            """)
        let center = try XCTUnwrap(value as? [Double])
        let local = NSPoint(x: center[0], y: view.isFlipped ? center[1] : view.bounds.height - center[1])
        let point = view.convert(local, to: nil)
        let content = try XCTUnwrap(window.contentView)
        let hit = try XCTUnwrap(content.hitTest(content.convert(point, from: nil)))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
        }
    }

    private func waitForJS<T: Equatable>(_ view: WKWebView, _ script: String, equals expected: T) async throws {
        let deadline = Date().addingTimeInterval(10)
        while (try? await view.evaluateJavaScript(script)) as? T != expected {
            guard Date() < deadline else { return XCTFail("\(script) never became \(expected)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("\(what) not reached within \(timeout)s") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
