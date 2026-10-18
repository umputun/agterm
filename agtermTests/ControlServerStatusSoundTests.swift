import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerStatusSoundTests: XCTestCase {
    private final class Surface: TerminalSurface {
        let paneToken: String
        var isRealized = true
        init(_ token: String) { paneToken = token }
        func teardown() {}
        func promoteToPrimaryPane() {}
    }

    private final class Viewer: PresentationSink {
        var frames: [PresentationFrame] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }
        func close(_: PresentationHub.CloseReason) {}
        var sounds: [PresentationSound] { frames.compactMap { if case .sound(let sound) = $0.body { sound } else { nil } } }
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var server: ControlServer!
    private var player: StatusSoundPlayer!
    private var sound: RecordingSound!
    private var playbackBarrier: RecordingSound!
    private var gate: StatusSoundResolutionGate!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-status-\(UUID().uuidString)")
        library = WindowLibrary(directory: stateDir)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        sound = try XCTUnwrap(RecordingSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true))
        playbackBarrier = try XCTUnwrap(RecordingSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true))
    }

    override func tearDown() async throws {
        gate?.release.signal()
        server = nil
        player = nil
        settings = nil
        library = nil
        sound = nil
        playbackBarrier = nil
        gate = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testUnknownSoundDoesNotMutateAndWinsOverMissingTarget() async throws {
        makeServer(resolvedSound: nil)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let before = session.agentIndicator
        let pending = Task { await self.update() }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(session.agentIndicator, before)
        gate.release.signal()
        let response = await pending.value
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.hasPrefix("unknown sound: held") == true)
        XCTAssertEqual(session.agentIndicator, before)

        let missing = await update(target: UUID().uuidString, soundName: "missing")
        XCTAssertTrue(missing.error?.hasPrefix("unknown sound: missing") == true)
    }

    func testActiveTargetStaysBoundDuringSelectionChange() async throws {
        makeServer(resolvedSound: sound)
        let store = try XCTUnwrap(library.activeStore)
        let original = try XCTUnwrap(store.activeSession)
        let other = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp"))
        store.selectSession(original.id)
        let pending = Task { await self.update() }
        await fulfillment(of: [gate.started], timeout: 2)
        store.selectSession(other.id)
        gate.release.signal()
        let response = await pending.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.id, original.id.uuidString)
        XCTAssertEqual(original.agentIndicator.status, .blocked)
        XCTAssertEqual(other.agentIndicator.status, .idle)
        await fulfillment(of: [sound.log.playCalled], timeout: 2)
        XCTAssertEqual(sound.log.calls.map(\.selector), ["stop", "play"])
    }

    func testClosedSessionDoesNotSucceedOrPlay() async throws {
        makeServer(resolvedSound: sound)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let pending = Task { await self.update() }
        await fulfillment(of: [gate.started], timeout: 2)
        store.closeSession(session.id)
        gate.release.signal()
        let response = await pending.value
        XCTAssertFalse(response.ok)
        await assertNoPlayback()
    }

    func testClosedWindowDoesNotMutateRetainedStoreOrPlay() async throws {
        makeServer(resolvedSound: sound)
        let window = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let pending = Task { await self.update() }
        await fulfillment(of: [gate.started], timeout: 2)
        library.closeWindow(window)
        gate.release.signal()
        let response = await pending.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(session.agentIndicator.status, .idle)
        await assertNoPlayback()
    }

    func testPaneRefusalUsesStateAfterResolutionAndDoesNotPlay() async throws {
        makeServer(resolvedSound: sound)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        session.hasSplit = true
        let pending = Task { await self.update(status: .completed, pane: .left) }
        await fulfillment(of: [gate.started], timeout: 2)
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        gate.release.signal()
        let response = await pending.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "blocked status owned by pane right (write from that pane to change it)")
        XCTAssertEqual(session.agentIndicator.status, .blocked)
        await assertNoPlayback()
    }

    func testInvalidBlockedDefaultDoesNotRejectOrDelayMutation() async throws {
        makeServer(resolvedSound: nil)
        settings.setBlockedStatusSoundName("held")
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let response = await update(soundName: nil)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(session.agentIndicator.status, .blocked)
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertFalse(gate.onMainThread)
        XCTAssertFalse(gate.finished, "the response must arrive before default sound resolution finishes")
        gate.release.signal()
        await fulfillment(of: [gate.completed], timeout: 2)
    }

    func testPaneTokenUsesRolesAfterResolution() async throws {
        makeServer(resolvedSound: sound)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let left = Surface("left-token")
        let right = Surface("right-token")
        session.surface = left
        session.splitSurface = right
        session.hasSplit = true
        let pending = Task { await self.update(pane: .right, paneID: "right-token") }
        await fulfillment(of: [gate.started], timeout: 2)
        session.surface = right
        session.splitSurface = left
        gate.release.signal()
        let response = await pending.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(session.agentIndicator.statusPane, .left)
        await fulfillment(of: [sound.log.playCalled], timeout: 2)
    }

    func testAFollowingPanesSoundPlaysOnThePresenterInsteadOfHere() async throws {
        makeServer(resolvedSound: sound)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let viewer = try present(session)
        let response = await update(soundName: "Tink")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(session.agentIndicator.status, .blocked)
        XCTAssertEqual(viewer.sounds, [PresentationSound(name: "Tink")])
        await assertNoPlayback()
    }

    func testEnteringBlockedSendsTheMarkerEvenWithNoBlockedSoundHere() async throws {
        makeServer(resolvedSound: sound)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let viewer = try present(session)
        let entered = await update(soundName: nil)
        XCTAssertTrue(entered.ok)
        XCTAssertEqual(viewer.sounds, [PresentationSound(name: nil)])
        let repeated = await update(soundName: nil)
        XCTAssertTrue(repeated.ok)
        XCTAssertEqual(viewer.sounds, [PresentationSound(name: nil)], "staying blocked plays nothing")
        let completed = await update(soundName: nil, status: .completed)
        XCTAssertTrue(completed.ok)
        XCTAssertEqual(viewer.sounds, [PresentationSound(name: nil)])
    }

    func testARefusedStatusSendsNoSound() async throws {
        makeServer(resolvedSound: sound)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        session.hasSplit = true
        let viewer = try present(session)
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        let response = await update(soundName: "Tink", status: .completed, pane: .left)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(viewer.sounds.isEmpty)
        await assertNoPlayback()
    }

    func testAPaneLeadingHerePlaysTheSoundHere() async throws {
        makeServer(resolvedSound: sound)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let viewer = try present(session, role: .leader)
        let response = await update(soundName: "Tink")
        XCTAssertTrue(response.ok)
        XCTAssertTrue(viewer.sounds.isEmpty)
        await fulfillment(of: [sound.log.playCalled], timeout: 2)
    }

    private func present(_ session: Session, role: ZmxLeadRole = .follower) throws -> Viewer {
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: session.paneIdentity)
        let notice = try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(role.rawValue):1"))
        _ = ZmxLeadBook.shared.apply(notice, pane: session.paneIdentity)
        server.attachPresentationHub()
        let viewer = Viewer()
        let hello = PresentationHello(version: 1, kinds: PresentationHub.supportedKinds, mode: .presenter)
        let id = try server.presentationHub.subscribe(session: session.id, hello: hello, sink: viewer) {
            PresentationSnapshot(status: nil, hud: nil)
        }
        server.presentationHub.receive(PresentationFrame(gen: viewer.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        XCTAssertTrue(server.presentationHub.hasPresenter(session: session.id))
        return viewer
    }

    private func makeServer(resolvedSound: NSSound?) {
        let gate = StatusSoundResolutionGate(sound: resolvedSound)
        self.gate = gate
        let barrier = playbackBarrier
        player = StatusSoundPlayer(resolve: { name in
            if name == "barrier" { return barrier }
            return name == "held" ? gate.resolve() : resolvedSound
        })
        server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                               identity: AppIdentity(version: "test", commit: "test"),
                               statusSoundPlayer: player,
                               socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    private func assertNoPlayback(file: StaticString = #filePath, line: UInt = #line) async {
        let action = await player.action(for: "barrier")
        action?()
        await fulfillment(of: [playbackBarrier.log.playCalled], timeout: 2)
        XCTAssertTrue(sound.log.calls.isEmpty, file: file, line: line)
    }

    private func update(target: String? = nil, soundName: String? = "held", status: AgentStatus = .blocked,
                        pane: StatusPane? = nil, paneID: String? = nil) async -> ControlResponse {
        let update = ControlSessionStatusUpdate(status: status, blink: nil, autoReset: nil, sound: soundName, pane: pane, paneID: paneID)
        return await server.setSessionStatus(target, window: nil, update: update)
    }
}
