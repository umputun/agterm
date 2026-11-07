import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemoteLinkClickTests: XCTestCase {
    private static let remoteLeft = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private var stateDir: URL!
    private var servers: [ControlServer] = []

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
            deliver.last?(Data(try PresentationCodec.encode(PresentationFrame(gen: 3, rev: rev, body: body)).dropLast()))
        }

        var clicks: [PresentationLinkClick] {
            links.last?.sent.compactMap { if case .linkClick(let click) = $0 { click } else { nil } } ?? []
        }
    }

    private final class Alerts: @unchecked Sendable {
        private let lock = NSLock()
        private var played = 0
        var count: Int { lock.withLock { played } }
        func add() { lock.withLock { played += 1 } }
    }

    private struct Fixture {
        let server: ControlServer
        let store: AppStore
        let session: Session
        let transport: Transport
        let alerts: Alerts
    }

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-link-click-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers.removeAll()
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testAClickTravelsToTheOriginWithItsPaneIdentityAndMode() throws {
        let fix = try connected()

        let refusal = fix.server.forwardRemoteLinkClick(click(fix.session, pane: fix.session.paneIdentity))

        XCTAssertNil(refusal)
        XCTAssertEqual(fix.transport.clicks, [PresentationLinkClick(raw: "src/a.py:3", pane: Self.remoteLeft, mode: .overlay75)])
    }

    func testAClickThatCannotTravelSendsNothing() throws {
        let old = try connected(kinds: [])
        XCTAssertEqual(old.server.forwardRemoteLinkClick(click(old.session, pane: old.session.paneIdentity)), .originTooOld)
        XCTAssertTrue(old.transport.clicks.isEmpty)

        let mirror = try connected(presenter: false)
        XCTAssertEqual(mirror.server.forwardRemoteLinkClick(click(mirror.session, pane: mirror.session.paneIdentity)),
                       .notPresenter)

        let fix = try connected()
        XCTAssertEqual(fix.server.forwardRemoteLinkClick(click(fix.session, pane: UUID())), .paneNotAttached)
        XCTAssertTrue(fix.server.openHud(fix.session.id.uuidString, window: nil, spec: HudSpec(message: "agent")).ok)
        XCTAssertEqual(fix.server.forwardRemoteLinkClick(click(fix.session, pane: fix.session.paneIdentity)), .hidden)
        XCTAssertTrue(fix.transport.clicks.isEmpty)
    }

    func testAnOriginRefusalShowsAPanelThatHidesItself() throws {
        let fix = try connected()

        try fix.transport.feed(.linkRefused(PresentationLinkRefusal(reason: .notFound)))

        XCTAssertTrue(fix.session.hudActive)
        XCTAssertEqual(fix.session.hudSpec?.message, RemoteLinkRefusal.notFound.message(host: "buildbox"))
        XCTAssertEqual(fix.session.hudSpec?.hideAfter, AppActions.remoteAttachErrorSeconds)
        XCTAssertEqual(fix.alerts.count, 0)
    }

    // regression: an origin HUD arriving while the refusal panel was up stayed hidden until the origin changed it
    func testAnOriginHudReplacesTheRefusalPanelButNotALaterLocalHud() throws {
        let fix = try connected()
        try fix.transport.feed(.snapshot(PresentationSnapshot(status: nil, hud: nil)))
        try fix.transport.feed(.linkRefused(PresentationLinkRefusal(reason: .notFound)))
        let origin = PresentationHud(spec: HudSpec(message: "deploying"), pane: nil, generation: 1, remaining: nil)

        try fix.transport.feed(.hud(origin))

        XCTAssertEqual(fix.session.hudSpec?.message, "deploying")
        XCTAssertEqual(fix.session.remotePresentation?.hudBridged, true)

        try fix.transport.feed(.hud(nil))
        fix.server.refuseRemoteLinkClick(.notFound, session: fix.session.id)
        XCTAssertTrue(fix.server.openHud(fix.session.id.uuidString, window: nil, spec: HudSpec(message: "agent")).ok)
        try fix.transport.feed(.hud(PresentationHud(spec: HudSpec(message: "again"), pane: nil, generation: 2, remaining: nil)))

        XCTAssertEqual(fix.session.hudSpec?.message, "agent")
    }

    // regression: the refusal panel turned the next valid click into a bare beep for as long as it was up
    func testAClickRightAfterARefusalStillTravels() throws {
        let fix = try connected()
        fix.server.refuseRemoteLinkClick(.notFound, session: fix.session.id)
        XCTAssertTrue(fix.session.hudActive)

        XCTAssertNil(fix.server.forwardRemoteLinkClick(click(fix.session, pane: fix.session.paneIdentity)))

        XCTAssertEqual(fix.transport.clicks.count, 1)
    }

    // regression: a hidden page of this Mac's own let the click through, and the origin's page then vanished unreported
    func testAHiddenLocalPageRefusesTheClickAndStays() async throws {
        let fix = try connected()
        let page = HtmlOverlay(source: .markdown(path: "/tmp/local.md"), clicked: true)
        XCTAssertNil(fix.store.openHtmlOverlay(fix.session.id, pane: nil, overlay: page, sizePercent: nil))
        fix.store.setOverlaysHidden(fix.session.id, pane: nil, hidden: true)

        let refusal = fix.server.forwardRemoteLinkClick(click(fix.session, pane: fix.session.paneIdentity))
        fix.server.refuseRemoteLinkClick(try XCTUnwrap(refusal), session: fix.session.id)

        XCTAssertEqual(refusal, .hidden)
        XCTAssertTrue(fix.transport.clicks.isEmpty)
        try await waitUntil { fix.alerts.count == 1 }
        XCTAssertEqual(fix.session.htmlOverlay?.id, page.id)
        XCTAssertTrue(fix.session.overlayHidden)
        fix.store.closeOverlay(fix.session.id)
    }

    func testAHiddenReplicaPageLetsTheClickTravel() throws {
        let fix = try connected()
        let replica = HtmlOverlay(source: .markdown(path: "/tmp/remote.md"), clicked: true, replicaOf: UUID())
        XCTAssertNil(fix.store.openHtmlOverlay(fix.session.id, pane: nil, overlay: replica, sizePercent: nil))
        fix.store.setOverlaysHidden(fix.session.id, pane: nil, hidden: true)

        XCTAssertNil(fix.server.forwardRemoteLinkClick(click(fix.session, pane: fix.session.paneIdentity)))

        XCTAssertEqual(fix.transport.clicks.count, 1)
        fix.store.closeOverlay(fix.session.id)
    }

    func testARefusalBeepsAndLeavesAHudAlreadyUp() async throws {
        let fix = try connected()
        XCTAssertTrue(fix.server.openHud(fix.session.id.uuidString, window: nil, spec: HudSpec(message: "agent")).ok)

        try fix.transport.feed(.linkRefused(PresentationLinkRefusal(reason: .notFound)))

        try await waitUntil { fix.alerts.count == 1 }
        XCTAssertEqual(fix.session.hudSpec?.message, "agent")
        XCTAssertNil(fix.session.hudSpec?.hideAfter)
    }

    func testARefusalBeepsUnderAZoomedTerminalOrACover() async throws {
        let fix = try connected()
        let windowID = try XCTUnwrap(fix.server.library.windowID(forSession: fix.session.id))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        zoom.set(.on, target: .session(fix.session.id, .primary))

        fix.server.refuseRemoteLinkClick(.notFound, session: fix.session.id)
        try await waitUntil { fix.alerts.count == 1 }
        XCTAssertFalse(fix.session.hudActive)
        TerminalZoomRegistry.shared.unregister(windowID)

        XCTAssertTrue(fix.store.openOverlay(fix.session.id, command: "/bin/cat", cwd: nil, wait: false, sizePercent: nil))
        try await Task.sleep(for: .milliseconds(250))
        fix.server.refuseRemoteLinkClick(.notOpened, session: fix.session.id)
        try await waitUntil { fix.alerts.count == 2 }
        XCTAssertFalse(fix.session.hudActive)
        fix.store.closeOverlay(fix.session.id)
    }

    private func connected(kinds: [String] = [PresentationHub.linkClickKind], presenter: Bool = true) throws -> Fixture {
        let library = WindowLibrary(directory: stateDir.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let alerts = Alerts()
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            statusSoundPlayer: StatusSoundPlayer(alert: { alerts.add() }),
            socketPath: "/tmp/agterm-rl-\(UUID().uuidString.prefix(8)).sock"
        )
        servers.append(server)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1",
                                       daemonsByLocalPane: [session.paneIdentity: ZmxSupport.daemonName(for: Self.remoteLeft)],
                                       presentationVersion: 1), forSession: session.id)
        let transport = Transport()
        server.remoteTransport = transport
        server.startRemotePresentation(for: session)
        try transport.feed(.hello(PresentationHello(version: 1, kinds: kinds, mode: presenter ? .presenter : .mirror)))
        if presenter { try transport.feed(.presenterGranted) }
        return Fixture(server: server, store: store, session: session, transport: transport, alerts: alerts)
    }

    private func click(_ session: Session, pane: UUID?) -> RemoteLinkClick {
        RemoteLinkClick(raw: "src/a.py:3", session: session.id, pane: pane, mode: .overlay75)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not reached") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
