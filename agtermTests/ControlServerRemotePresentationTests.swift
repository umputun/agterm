import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemotePresentationTests: XCTestCase {
    private var stateDir: URL!
    private var servers: [ControlServer] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-presentation-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers.removeAll()
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func fixture() throws -> (server: ControlServer, store: AppStore, session: Session) {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: "/tmp/agterm-rp-\(UUID().uuidString.prefix(8)).sock"
        )
        servers.append(server)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(),
                                                     remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [:], presentationVersion: 1),
                         forSession: session.id)
        return (server, store, session)
    }

    private func hud(_ message: String, remaining: Double? = nil, generation: Int = 1) -> PresentationHud {
        PresentationHud(spec: HudSpec(message: message, hideAfter: 600), pane: nil, generation: generation,
                        remaining: remaining)
    }

    private func body(of session: Session) -> String {
        (try? String(contentsOfFile: ControlServer.bodyFile(for: session.id), encoding: .utf8)) ?? ""
    }

    func testAMirroredHudIsWrittenToThePanelAndMarkedAsTheBridges() throws {
        let fix = try fixture()

        fix.server.showRemoteHud(hud("deploying"), forSession: fix.session.id)

        XCTAssertTrue(fix.session.hudActive)
        XCTAssertTrue(body(of: fix.session).contains("deploying"), "the panel's body is on disk, not only in the model")
        XCTAssertEqual(fix.session.remotePresentation?.hudBridged, true)
    }

    func testTheViewerCountsDownWhatIsLeftNotTheConfiguredInterval() throws {
        let fix = try fixture()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        fix.server.hudClock = { start }

        fix.server.showRemoteHud(hud("deploying", remaining: 7), forSession: fix.session.id)

        XCTAssertEqual(fix.server.hudAutoHide[fix.session.id]?.deadline, start.addingTimeInterval(7))
    }

    func testAPersistentOriginPanelArmsNoTimerHere() throws {
        let fix = try fixture()

        fix.server.showRemoteHud(hud("waiting"), forSession: fix.session.id)

        XCTAssertNil(fix.server.hudAutoHide[fix.session.id])
    }

    func testAnUpdateRepaintsInPlace() throws {
        let fix = try fixture()
        fix.server.showRemoteHud(hud("one"), forSession: fix.session.id)
        let slot = fix.session.overlaySlotGeneration

        fix.server.showRemoteHud(hud("two", generation: 2), forSession: fix.session.id)

        XCTAssertEqual(fix.session.overlaySlotGeneration, slot, "an update must not re-create the panel's surface")
        XCTAssertTrue(body(of: fix.session).contains("two"))
    }

    func testAPaneHiddenHereKeepsTheMirroredPanelSessionWideAcrossUpdates() throws {
        let fix = try fixture()
        let remoteRight = UUID()
        fix.store.toggleSplit(fix.session.id)
        let split = try XCTUnwrap(fix.session.splitPaneIdentity)
        fix.store.bindRemote(RemoteBinding(remoteSessionID: "s1",
                                           daemonsByLocalPane: [split: ZmxSupport.daemonName(for: remoteRight)],
                                           presentationVersion: 1), forSession: fix.session.id)
        fix.store.setSplitVisibility(fix.session.id, shown: false)
        let first = PresentationHud(spec: HudSpec(message: "one"), pane: .identity(remoteRight), generation: 1,
                                    remaining: nil)
        let second = PresentationHud(spec: HudSpec(message: "two"), pane: .identity(remoteRight), generation: 2,
                                     remaining: nil)

        fix.server.showRemoteHud(first, forSession: fix.session.id)
        XCTAssertNil(fix.session.hudPaneIdentity)
        fix.server.showRemoteHud(second, forSession: fix.session.id)

        XCTAssertTrue(fix.session.hudActive)
        XCTAssertNil(fix.session.hudPaneIdentity, "an update must not move the panel onto a pane the deck does not lay out")
        XCTAssertTrue(body(of: fix.session).contains("two"))
    }

    func testAbsenceTakesTheMirroredPanelDown() throws {
        let fix = try fixture()
        fix.server.showRemoteHud(hud("deploying"), forSession: fix.session.id)

        fix.server.showRemoteHud(nil, forSession: fix.session.id)

        XCTAssertFalse(fix.session.hudActive)
    }

    func testAPanelWithNothingLeftIsNotShown() throws {
        let fix = try fixture()

        fix.server.showRemoteHud(hud("late", remaining: 0), forSession: fix.session.id)

        XCTAssertFalse(fix.session.hudActive)
    }

    func testAPanelThisMacsOwnProgramOpenedIsNeitherReplacedNorClosed() throws {
        let fix = try fixture()
        XCTAssertTrue(fix.server.openHud(fix.session.id.uuidString, window: nil, spec: HudSpec(message: "local")).ok)

        fix.server.showRemoteHud(hud("mirrored"), forSession: fix.session.id)
        fix.server.showRemoteHud(nil, forSession: fix.session.id)

        XCTAssertTrue(fix.session.hudActive)
        XCTAssertTrue(body(of: fix.session).contains("local"))
        XCTAssertEqual(fix.session.remotePresentation?.hudBridged, false)
    }

    func testAMirroredPanelYieldsToAProgramOverlay() throws {
        let fix = try fixture()
        XCTAssertTrue(fix.store.openOverlay(fix.session.id, command: "htop"))

        fix.server.showRemoteHud(hud("mirrored"), forSession: fix.session.id)

        XCTAssertTrue(fix.session.programOverlayActive)
        XCTAssertFalse(fix.session.hudActive)
        XCTAssertEqual(fix.session.remotePresentation?.hudBridged, false)
    }

    func testASessionThatIsNotAttachedIgnoresAMirroredPanel() throws {
        let fix = try fixture()
        let workspace = try XCTUnwrap(fix.store.currentWorkspaceID)
        let local = try XCTUnwrap(fix.store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))

        fix.server.showRemoteHud(hud("mirrored"), forSession: local.id)

        XCTAssertFalse(local.hudActive)
    }
}
