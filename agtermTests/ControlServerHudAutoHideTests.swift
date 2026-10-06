import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the HUD auto-hide timer. The scheduler is `ControlServer`'s and the panel lives in a
/// real store, so this cannot move to `agtermCore`.
@MainActor
final class ControlServerHudAutoHideTests: XCTestCase {
    private var stateDir: URL!
    private var servers: [ControlServer] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-hud-autohide-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers.removeAll()
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testAPanelWithNoAutoHideArmsNothing() throws {
        let fix = try fixture()

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "waiting"))

        XCTAssertNil(fix.server.hudAutoHide[fix.session.id])
    }

    func testRearmingSupersedesTheEarlierTimer() throws {
        let fix = try fixture()

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))
        let first = try XCTUnwrap(fix.server.hudAutoHide[fix.session.id]).revision
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "two", hideAfter: 30))
        let second = try XCTUnwrap(fix.server.hudAutoHide[fix.session.id]).revision

        XCTAssertGreaterThan(second, first, "an update restarts the interval without touching the slot generation")
    }

    func testRearmingWithoutAnAutoHideCancelsTheRunningOne() throws {
        let fix = try fixture()
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "two"))

        XCTAssertNil(fix.server.hudAutoHide[fix.session.id], "omitting it is how a caller cancels")
    }

    func testDiscardingTheHudDropsItsTimer() throws {
        let fix = try fixture()
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))

        fix.session.discardHudBody()

        XCTAssertNil(fix.server.hudAutoHide[fix.session.id], "every teardown routes through discardHudBody")
    }

    func testAnExpiredTimerClosesThePanel() async throws {
        let fix = try fixture()
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 0.05))

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(fix.session.hudActive)
        XCTAssertNil(fix.server.hudAutoHide[fix.session.id])
    }

    func testAnOpenMeasuresAndRecordsTheRequestedFontSize() throws {
        let fix = try fixture()
        XCTAssertTrue(try XCTUnwrap(fix.server.library.activeStore).closeHud(fix.session.id))

        let response = fix.server.openHud(fix.session.id.uuidString, window: nil,
                                          spec: HudSpec(message: "big", fontSize: 30), placement: ControlHudPlacement())

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(fix.session.hudFontSize, 30)
        XCTAssertEqual(fix.server.liveHudFontSize(fix.session), 30)
    }

    func testAnOpenWithoutAFontSizeRecordsTheSessionsSize() throws {
        let fix = try fixture()
        XCTAssertTrue(try XCTUnwrap(fix.server.library.activeStore).closeHud(fix.session.id))
        try XCTUnwrap(fix.server.library.activeStore).setFontSize(fix.session.id, 17)

        let response = fix.server.openHud(fix.session.id.uuidString, window: nil,
                                          spec: HudSpec(message: "same"), placement: ControlHudPlacement())

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(fix.session.hudFontSize, 17)
    }

    func testAnUpdateAndASessionZoomKeepTheOpenedFontSize() throws {
        let fix = try fixture()
        XCTAssertTrue(try XCTUnwrap(fix.server.library.activeStore).closeHud(fix.session.id))
        _ = fix.server.openHud(fix.session.id.uuidString, window: nil,
                               spec: HudSpec(message: "a", fontSize: 30), placement: ControlHudPlacement())
        try XCTUnwrap(fix.server.library.activeStore).setFontSize(fix.session.id, 11)

        let response = fix.server.updateHud(fix.session.id.uuidString, window: nil, spec: HudSpec(message: "b"))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(fix.server.liveHudFontSize(fix.session), 30)
        XCTAssertEqual(fix.session.hudSpec?.fontSize, 30)
    }

    func testClosingTheHudDropsItsGeometryHook() throws {
        let fix = try fixture()
        XCTAssertTrue(try XCTUnwrap(fix.server.library.activeStore).closeHud(fix.session.id))
        XCTAssertTrue(fix.server.openHud(fix.session.id.uuidString, window: nil, spec: HudSpec(message: "a"),
                                         placement: ControlHudPlacement()).ok)
        XCTAssertNotNil(fix.session.onHudGeometryChange)

        XCTAssertTrue(try XCTUnwrap(fix.server.library.activeStore).closeHud(fix.session.id))

        XCTAssertNil(fix.session.onHudGeometryChange)
    }

    func testTheMeasuredCellFollowsTheFontSizeItIsGiven() throws {
        let fix = try fixture()

        let small = fix.server.paneMetrics(for: fix.session, fontSize: 10)
        let large = fix.server.paneMetrics(for: fix.session, fontSize: 30)

        XCTAssertGreaterThan(large.cellWidth, small.cellWidth)
        XCTAssertGreaterThan(large.cellHeight, small.cellHeight)
    }

    @MainActor
    private final class HudSink: PresentationSink {
        var huds: [PresentationHud?] = []
        var snapshot: PresentationSnapshot?
        func offer(_ frame: PresentationFrame) -> Bool {
            switch frame.body {
            case .hud(let hud): huds.append(hud)
            case .snapshot(let state): snapshot = state
            default: break
            }
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}
    }

    private func mirror(_ fix: (server: ControlServer, session: Session), at now: Date) throws -> HudSink {
        let store = try XCTUnwrap(fix.server.library.store(forSession: fix.session.id))
        let hub = try XCTUnwrap(store.presentationHub)
        let sink = HudSink()
        let id = fix.session.id
        try hub.subscribe(session: id, hello: PresentationHello(version: 1, kinds: ["hud"], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: id, now: now) }
        return sink
    }

    func testArmingPublishesThePanelWithItsDeadline() throws {
        let fix = try fixture()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        fix.server.hudClock = { start }
        let sink = try mirror(fix, at: start)

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))

        XCTAssertEqual(sink.huds.last??.remaining, 30)
        XCTAssertEqual(fix.server.hudAutoHide[fix.session.id]?.deadline, start.addingTimeInterval(30))
    }

    func testALateSubscriberGetsWhatIsLeftOfTheInterval() throws {
        let fix = try fixture()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        fix.server.hudClock = { start }
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))

        let late = try mirror(fix, at: start.addingTimeInterval(20))

        XCTAssertEqual(late.snapshot?.hud?.remaining, 10)
    }

    func testAPersistentPanelPublishesWithNoRemainingLifetime() throws {
        let fix = try fixture()
        let sink = try mirror(fix, at: Date())

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "waiting"))

        XCTAssertEqual(sink.huds.count, 1)
        XCTAssertNil(sink.huds.last??.remaining)
    }

    func testResizingAPublishedPanelRepublishesItsWidthWithoutRestartingTheInterval() throws {
        let fix = try fixture()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        fix.server.hudClock = { start }
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))
        let sink = try mirror(fix, at: start)
        fix.server.hudClock = { start.addingTimeInterval(12) }

        let response = fix.server.resizeSessionOverlay(fix.session.id.uuidString, window: nil, sizePercent: 60)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(sink.huds.last??.spec.sizePercent, 60)
        XCTAssertEqual(sink.huds.last??.remaining, 18)
        XCTAssertEqual(fix.server.hudAutoHide[fix.session.id]?.deadline, start.addingTimeInterval(30))
    }

    func testAnExpiredTimerWithdrawsThePanelFromViewers() async throws {
        let fix = try fixture()
        let sink = try mirror(fix, at: Date())
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 0.05))

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(sink.huds.count, 2)
        XCTAssertNil(sink.huds.last ?? nil)
    }

    // MARK: - geometry

    // regression: the height was a saved percent of the pane, so the panel grew with the window
    func testAHudKeepsItsHeightWhenOnlyThePaneHeightChanges() async throws {
        let fix = try fixture()
        try openMeasuredHud(fix, spec: HudSpec(message: "working on it"))
        let points = try XCTUnwrap(fix.session.hudHeightPoints)
        let percent = try XCTUnwrap(fix.session.hudHeightPercent)

        await changeLeftPane(fix, width: 1_600, height: 500)

        XCTAssertEqual(fix.session.hudHeightPoints, points)
        XCTAssertGreaterThan(try XCTUnwrap(fix.session.hudHeightPercent), percent)
        let style = OverlayPanelStyle.resolve(fix.session)
        XCTAssertEqual(style.panelFrame(in: CGRect(x: 0, y: 0, width: 1_600, height: 500)).height, points, accuracy: 0.001)
        XCTAssertEqual(style.panelFrame(in: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)).height, points, accuracy: 0.001)
    }

    func testANarrowedPaneRewrapsAMarkdownHudAndGrowsItByTheAddedRow() async throws {
        let fix = try fixture()
        let message = String(repeating: "a", count: 20) + " " + String(repeating: "b", count: 20)
        try openMeasuredHud(fix, spec: HudSpec(message: message, hideAfter: 30, markdown: true))
        let points = try XCTUnwrap(fix.session.hudHeightPoints)
        let generation = fix.session.overlaySlotGeneration
        let timer = try XCTUnwrap(fix.server.hudAutoHide[fix.session.id])

        await changeLeftPane(fix, width: 400, height: 1_000)

        let metrics = fix.server.paneMetrics(for: fix.session, pane: .left,
                                             fontSize: fix.server.liveHudFontSize(fix.session))
        XCTAssertEqual(try XCTUnwrap(fix.session.hudHeightPoints), points + metrics.cellHeight, accuracy: 0.001)
        let size = try XCTUnwrap(fix.session.hudPanelSize)
        let spec = try XCTUnwrap(fix.session.effectiveHudSpec)
        let body = try String(contentsOfFile: ControlServer.bodyFile(for: fix.session.id), encoding: .utf8)
        XCTAssertEqual(body, HudLayout.renderedBody(for: spec, grid: HudLayout.paintGrid(for: spec, size: size, pane: metrics),
                                                    ownerPid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(fix.session.overlaySlotGeneration, generation, "a remeasure must not re-host the surface")
        XCTAssertEqual(fix.server.hudAutoHide[fix.session.id]?.revision, timer.revision)
        XCTAssertEqual(fix.server.hudAutoHide[fix.session.id]?.deadline, timer.deadline)
    }

    func testAWidthForcedByResizeHoldsThroughAGeometryChangeUntilTheNextUpdate() async throws {
        let fix = try fixture()
        let id = fix.session.id.uuidString
        try openMeasuredHud(fix, spec: HudSpec(message: "working on it"))
        XCTAssertTrue(fix.server.resizeSessionOverlay(id, window: nil, sizePercent: 50).ok)

        await changeLeftPane(fix, width: 900, height: 700)

        XCTAssertEqual(fix.session.overlaySizePercent, 50)
        XCTAssertEqual(fix.session.effectiveHudSpec?.sizePercent, 50)
        XCTAssertNil(fix.session.hudSpec?.sizePercent, "the caller's own spec keeps the width he sent")

        XCTAssertTrue(fix.server.updateHud(id, window: nil, spec: HudSpec(message: "done"),
                                           placement: ControlHudPlacement(pane: .left)).ok)
        XCTAssertNil(fix.session.hudResizedWidthPercent)
    }

    func testAResizedUnsizedMarkdownHudWrapsAtTheWidthItWasResizedTo() async throws {
        let fix = try fixture()
        let line = Array(repeating: "word", count: 20).joined(separator: " ")
        try openMeasuredHud(fix, spec: HudSpec(message: line, markdown: true))
        let wrapped = try XCTUnwrap(fix.session.hudHeightPoints)

        XCTAssertTrue(fix.server.resizeSessionOverlay(fix.session.id.uuidString, window: nil, sizePercent: 80).ok)

        let cell = fix.server.paneMetrics(for: fix.session, pane: .left,
                                          fontSize: fix.server.liveHudFontSize(fix.session)).cellHeight
        XCTAssertEqual(try XCTUnwrap(fix.session.hudHeightPoints), wrapped - cell, accuracy: 0.001)
    }

    // regression: a session-wide panel was measured from the terminal views, which zoom and the dashboard
    // move to another host, and not from the detail area it is drawn in
    func testASessionWideHudIsMeasuredFromTheDetailAreaItIsDrawnIn() async throws {
        let fix = try fixture()
        let session = fix.session
        addTeardownBlock { try? FileManager.default.removeItem(atPath: ControlServer.bodyFile(for: session.id)) }
        let message = String(repeating: "a", count: 20) + " " + String(repeating: "b", count: 20)
        session.hudPaneFrames = HudPaneFrames(detail: HudPaneFrame(x: 0, y: 0, width: 1_600, height: 1_000))
        XCTAssertTrue(fix.server.openHud(session.id.uuidString, window: nil,
                                         spec: HudSpec(message: message, markdown: true)).ok)
        let points = try XCTUnwrap(session.hudHeightPoints, "no terminal view is laid out here, so only the detail area can measure it")

        session.hudPaneFrames.detail = HudPaneFrame(x: 0, y: 0, width: 400, height: 1_000)
        session.onHudGeometryChange?()
        await drainGeometry(fix)

        let cell = fix.server.paneMetrics(for: session, fontSize: fix.server.liveHudFontSize(session)).cellHeight
        XCTAssertEqual(try XCTUnwrap(session.hudHeightPoints), points + cell, accuracy: 0.001)
    }

    // regression: a config reload that changed the panel's cell left it at the old row height
    func testAChangedCellOnTheLivePanelRemeasuresItAtAnUnchangedFrame() async throws {
        let fix = try fixture()
        let session = fix.session
        try openMeasuredHud(fix, spec: HudSpec(message: "- a\n- b", markdown: true, frame: false))
        let panel = HudGeometryTestSurface(paneToken: "panel")
        panel.cell = (width: 9, height: 21)
        session.overlaySurface = panel

        session.onHudGeometryChange?()
        await drainGeometry(fix)

        XCTAssertEqual(try XCTUnwrap(session.hudHeightPoints), 2 * 21 + 12, accuracy: 0.001)
        let size = try XCTUnwrap(session.hudPanelSize)
        let metrics = fix.server.paneMetrics(for: session, pane: .left, fontSize: fix.server.liveHudFontSize(session))
        XCTAssertEqual(metrics.cellHeight, 21)
        XCTAssertEqual(HudLayout.paintGrid(for: try XCTUnwrap(session.effectiveHudSpec), size: size, pane: metrics).rows, 2)
    }

    private func openMeasuredHud(_ fix: (server: ControlServer, session: Session), spec: HudSpec) throws {
        let session = fix.session
        session.splitPaneIdentity = UUID()
        session.hasSplit = true
        session.isSplit = true
        session.surface = HudGeometryTestSurface(paneToken: "left-token")
        session.splitSurface = HudGeometryTestSurface(paneToken: "right-token")
        setLeftPane(session, width: 1_600, height: 1_000)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: ControlServer.bodyFile(for: session.id)) }
        let response = fix.server.openHud(session.id.uuidString, window: nil, spec: spec,
                                          placement: ControlHudPlacement(pane: .left))
        XCTAssertTrue(response.ok, response.error ?? "")
    }

    private func setLeftPane(_ session: Session, width: Double, height: Double) {
        session.hudPaneFrames = HudPaneFrames(left: HudPaneFrame(x: 0, y: 0, width: width, height: height),
                                              right: HudPaneFrame(x: width + 4, y: 0, width: 400, height: height))
    }

    private func changeLeftPane(_ fix: (server: ControlServer, session: Session), width: Double, height: Double) async {
        setLeftPane(fix.session, width: width, height: height)
        fix.session.onHudGeometryChange?()
        await drainGeometry(fix)
    }

    private func drainGeometry(_ fix: (server: ControlServer, session: Session)) async {
        for _ in 0..<50 where fix.server.hudGeometryPending.contains(fix.session.id) { await Task.yield() }
        XCTAssertTrue(fix.server.hudGeometryPending.isEmpty)
    }

    private func fixture() throws -> (server: ControlServer, session: Session) {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: "/tmp/agterm-hud-\(UUID().uuidString.prefix(8)).sock"
        )
        servers.append(server)
        let store = try XCTUnwrap(library.activeStore)
        store.presentationHub = PresentationHub(staleTimeout: 30)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one", hideAfter: 30),
                      file: stateDir.appendingPathComponent("body").path,
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        return (server, session)
    }
}

@MainActor
private final class HudGeometryTestSurface: TerminalSurface, HudPanelSurface {
    let paneToken: String
    let isRealized = true

    init(paneToken: String) { self.paneToken = paneToken }
    var cell: (width: Double, height: Double)?

    func cellSize() -> (width: Double, height: Double)? { cell }
    func teardown() {}
    func promoteToPrimaryPane() {}
}
