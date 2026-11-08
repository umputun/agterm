import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerForwardedClickTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    private final class Presenter: PresentationSink {
        var generation = 0
        var bodies: [PresentationFrame.Body] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            if bodies.isEmpty { generation = frame.gen }
            bodies.append(frame.body)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var requests: [PresentationPage] { bodies.compactMap { if case .pageRequest(let page) = $0 { page } else { nil } } }
        var refusals: [RemoteLinkRefusal] {
            bodies.compactMap { if case .linkRefused(let refusal) = $0 { refusal.reason } else { nil } }
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-forwarded-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
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
        server.stop()
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    func testEachPageKindAClickNamesOpensOnThePresenterAndNothingHere() async throws {
        let (store, session) = try addSession()
        let presenter = try present(session)
        let files = try ["a.md", "b.txt", "c.html"].map { try write($0, "# a\n") } + [try writePNG()]
        let sources: [(String) -> PresentationPageSource] = [
            { .markdown(path: $0) }, { .text(path: $0, line: nil) }, { .document(path: $0) },
        ]

        for (index, file) in files.enumerated() {
            click(file, in: session, pane: session.paneIdentity)
            try await waitUntil { presenter.requests.count == index + 1 }
            XCTAssertTrue(store.closeRemoteOverlay(session.id, pane: nil))
        }

        for (file, source) in zip(files, sources) {
            XCTAssertTrue(presenter.requests.contains { $0.source == source(file) }, file)
        }
        XCTAssertTrue(presenter.requests.contains { if case .image(let path, _, _) = $0.source { path == files[3] } else { false } })
        XCTAssertTrue(presenter.refusals.isEmpty)
        XCTAssertNil(session.htmlOverlay)
    }

    func testARelativePathOpensAtItsLineAgainstTheClickedPanesOwnDirectory() async throws {
        let (store, session) = try addSession()
        store.toggleSplit(session.id)
        let left = stateDir.appendingPathComponent("left/src", isDirectory: true)
        let right = stateDir.appendingPathComponent("right/src", isDirectory: true)
        for dir in [left, right] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x = 1\n".utf8).write(to: dir.appendingPathComponent("x.py"))
        }
        session.currentCwd = left.deletingLastPathComponent().path
        session.splitCwd = right.deletingLastPathComponent().path
        let presenter = try present(session)

        click("src/x.py:42", in: session, pane: session.paneIdentity)
        try await waitUntil { presenter.requests.count == 1 }
        XCTAssertTrue(store.closeRemoteOverlay(session.id, pane: nil))
        click("./src/x.py", in: session, pane: try XCTUnwrap(session.splitPaneIdentity))
        try await waitUntil { presenter.requests.count == 2 }

        XCTAssertEqual(presenter.requests.map(\.source), [.text(path: left.appendingPathComponent("x.py").path, line: 42),
                                                         .text(path: right.appendingPathComponent("x.py").path, line: nil)])
        XCTAssertTrue(presenter.refusals.isEmpty)
    }

    func testThePageTakesTheSizeTheClickersModeNames() async throws {
        let (_, session) = try addSession()
        let presenter = try present(session)
        let file = try write("a.md", "# a\n")

        click(file, in: session, pane: session.paneIdentity, mode: .overlay75)
        try await waitUntil { presenter.requests.count == 1 }

        XCTAssertEqual(presenter.requests.first?.sizePercent, 75)
    }

    func testAClickedMarkdownFileReachesThePresenterWithNavigationAndItsLinkGrant() async throws {
        let (_, session) = try addSession()
        let presenter = try present(session)
        let file = try write("a.md", "# a\n")

        click(file, in: session, pane: session.paneIdentity)
        try await waitUntil { presenter.requests.count == 1 }

        XCTAssertEqual(presenter.requests.first?.navigation, true)
        XCTAssertEqual(presenter.requests.first?.markdownLinks, MarkdownPage.linkGrant(for: file))
        XCTAssertNotNil(presenter.requests.first?.markdownLinks)
    }

    func testABrowserModeClickOpensAtNinetyFivePercent() async throws {
        let (_, session) = try addSession()
        let presenter = try present(session)

        click(try write("a.md", "# a\n"), in: session, pane: session.paneIdentity, mode: .browser)
        try await waitUntil { presenter.requests.count == 1 }

        XCTAssertEqual(presenter.requests.first?.sizePercent, 95)
    }

    func testAClickThatNamesNoPageIsRefusedOnceAndOpensNothing() async throws {
        let (_, session) = try addSession()
        let presenter = try present(session)
        let binary = try write("blob.bin", "\u{1}")
        let cases: [(String, UUID, RemoteLinkRefusal)] = [
            (stateDir.appendingPathComponent("gone.md").path, session.paneIdentity, .notFound),
            ("src/gone.py:3", session.paneIdentity, .notFound),
            (binary, session.paneIdentity, .notAPage),
            ("https://example.com/a", session.paneIdentity, .notAPage),
            (try write("x.md", "# x\n"), UUID(), .paneNotAttached),
        ]

        for (raw, pane, _) in cases {
            let before = presenter.refusals.count
            click(raw, in: session, pane: pane)
            try await waitUntil { presenter.refusals.count == before + 1 }
        }

        XCTAssertEqual(presenter.refusals, cases.map(\.2))
        XCTAssertTrue(presenter.requests.isEmpty)
        XCTAssertNil(session.htmlOverlay)
    }

    func testAClickIntoABusySlotIsRefused() async throws {
        let (store, session) = try addSession()
        let presenter = try present(session)
        XCTAssertTrue(store.openOverlay(session.id, command: "/bin/cat", cwd: nil, wait: false, sizePercent: nil))

        click(try write("a.md", "# a\n"), in: session, pane: session.paneIdentity)
        try await waitUntil { !presenter.refusals.isEmpty }

        XCTAssertEqual(presenter.refusals, [.notOpened])
        XCTAssertTrue(presenter.requests.isEmpty)
        store.closeOverlay(session.id)
    }

    func testEveryPageKindIsRefusedWhenAPaneLedHereKeepsItHere() async throws {
        let (store, session) = try addSession()
        store.toggleSplit(session.id)
        let presenter = try present(session)
        lead(.leader, pane: try XCTUnwrap(session.splitPaneIdentity))
        let files = try ["a.md", "b.txt", "c.html"].map { try write($0, "# a\n") } + [try writePNG()]

        for file in files {
            let before = presenter.refusals.count
            click(file, in: session, pane: session.paneIdentity)
            try await waitUntil { presenter.refusals.count == before + 1 }
        }

        XCTAssertEqual(presenter.refusals, Array(repeating: .notOpened, count: files.count))
        XCTAssertTrue(presenter.requests.isEmpty)
        XCTAssertNil(session.htmlOverlay)
    }

    func testAZoomedTerminalOnThisMacDoesNotBlockAForwardedClick() async throws {
        let (_, session) = try addSession()
        let presenter = try present(session)
        let windowID = try XCTUnwrap(library.windowID(forSession: session.id))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        zoom.set(.on, target: .session(session.id, .primary))

        click(try write("a.md", "# a\n"), in: session, pane: session.paneIdentity)
        try await waitUntil { presenter.requests.count == 1 }

        XCTAssertTrue(presenter.refusals.isEmpty)
    }

    func testAForwardedClickReplacesItsHiddenPageAndKeepsItWhenTheNewFileIsMissing() async throws {
        let (_, session) = try addSession()
        let presenter = try present(session)
        click(try write("a.md", "# a\n"), in: session, pane: session.paneIdentity)
        try await waitUntil { presenter.requests.count == 1 }
        let first = try XCTUnwrap(presenter.requests.first)
        hide(first.page, in: session)

        click(stateDir.appendingPathComponent("gone.md").path, in: session, pane: session.paneIdentity)
        try await waitUntil { presenter.refusals.count == 1 }
        XCTAssertEqual(session.remoteOverlays.slot(nil)?.job, first.page)

        click(try write("b.md", "# b\n"), in: session, pane: session.paneIdentity)
        try await waitUntil { presenter.requests.count == 2 }

        XCTAssertTrue(presenter.bodies.contains(.pageClose(PresentationPageChange(page: first.page))))
        XCTAssertEqual(session.remoteOverlays.slot(nil)?.job, presenter.requests.last?.page)
    }

    // regression: a refused forwarded click released the hidden clicked page this Mac shows itself
    func testARefusedForwardedClickLeavesAHiddenPageShownHere() async throws {
        let (store, session) = try addSession()
        store.toggleSplit(session.id)
        let presenter = try present(session)
        lead(.leader, pane: try XCTUnwrap(session.splitPaneIdentity))
        let local = URL(fileURLWithPath: try write("local.md", "# local\n"))
        let opened = await withCheckedContinuation { continuation in
            server.openMarkdownLink(local, session: session.id, sizePercent: nil) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(opened)
        let page = try XCTUnwrap(session.htmlOverlay?.id)
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)
        let files = try ["a.md", "b.txt", "c.html"].map { try write($0, "# a\n") } + [try writePNG()]

        for file in files {
            let before = presenter.refusals.count
            click(file, in: session, pane: session.paneIdentity)
            try await waitUntil { presenter.refusals.count == before + 1 }
        }

        XCTAssertEqual(presenter.refusals, Array(repeating: .notOpened, count: files.count))
        XCTAssertTrue(presenter.requests.isEmpty)
        XCTAssertEqual(session.htmlOverlay?.id, page)
        XCTAssertTrue(session.overlayHidden)
        store.closeOverlay(session.id)
    }

    func testAClickWhosePresenterChangedBeforeItsProbeEndedDoesNothing() async throws {
        let (_, session) = try addSession()
        let presenter = try present(session)
        let id = try XCTUnwrap(subscriber)

        click(try write("a.md", "# a\n"), in: session, pane: session.paneIdentity)
        server.presentationHub.unsubscribe(id)
        let next = try present(session)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(presenter.requests.isEmpty && presenter.refusals.isEmpty)
        XCTAssertTrue(next.requests.isEmpty && next.refusals.isEmpty)
        XCTAssertNil(session.remoteOverlays.slot(nil))
        XCTAssertNil(session.htmlOverlay)
    }

    private var subscriber: PresentationHub.SubscriberID?

    private func present(_ session: Session) throws -> Presenter {
        for pane in [session.paneIdentity] + [session.splitPaneIdentity].compactMap({ $0 }) { lead(.follower, pane: pane) }
        server.attachPresentationHub()
        let sink = Presenter()
        let kinds = PresentationHub.pageKinds + [PresentationHub.pageContentKind, PresentationHub.pageDocumentKind,
                                                 PresentationHub.linkClickKind, PresentationHub.pageLinksKind]
        let id = try server.presentationHub.subscribe(
            session: session.id, hello: PresentationHello(version: 1, kinds: kinds, mode: .presenter), sink: sink
        ) { PresentationSnapshot(status: nil, hud: nil) }
        server.presentationHub.receive(PresentationFrame(gen: sink.generation, rev: 0, body: .presenterAcquire), from: id)
        subscriber = id
        return sink
    }

    private func click(_ raw: String, in session: Session, pane: UUID, mode: LinkOpenMode = .overlay) {
        server.receiveForwardedClick(PresentationLinkClick(raw: raw, pane: pane, mode: mode), forSession: session.id)
    }

    private func hide(_ page: String, in session: Session) {
        server.library.store(forSession: session.id)?.receiveRemotePageFrame(.pageState(PresentationPageState(
            page: page, title: nil, address: nil, load: .loaded, error: nil, canGoBack: false, canGoForward: false,
            hidden: true, appliedSeq: 0)), forSession: session.id)
    }

    private func lead(_ role: ZmxLeadRole, pane: UUID) {
        let attachment = ZmxLeadAttachment(claim: true)
        ZmxLeadBook.shared.begin(attachment, pane: pane)
        if let notice = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(role.rawValue):1") {
            _ = ZmxLeadBook.shared.apply(notice, pane: pane)
        }
    }

    private func write(_ name: String, _ text: String) throws -> String {
        let url = stateDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func writePNG() throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = stateDir.appendingPathComponent("shot.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not reached") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: stateDir.path)))
    }
}
