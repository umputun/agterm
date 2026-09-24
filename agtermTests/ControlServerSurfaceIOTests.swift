import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerSurfaceIOTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-surface-io-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func makeServer() -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                      identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                      socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    private func makeSession(split: Bool) throws -> (store: AppStore, session: Session) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
        session.surface = realizedView(session: session)
        if split {
            store.toggleSplit(session.id)
            let right = realizedView(session: session)
            right.isSplitPane = true
            session.splitSurface = right
        }
        return (store, session)
    }

    private func addScratch(to session: Session) -> GhosttySurfaceView {
        let scratch = realizedView(session: nil)
        scratch.watermarkSession = session
        session.scratchSurface = scratch
        return scratch
    }

    private func realizedView(session: Session?) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: 12, command: "/bin/cat")
        view.session = session
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(view.isRealized)
        return view
    }

    private func set(_ server: ControlServer, _ session: Session, _ watermark: BackgroundWatermark?,
                     pane: StatusPane? = nil) -> ControlResponse {
        server.setSessionBackground(session.id.uuidString, window: nil,
                                    options: ControlSessionBackgroundOptions(watermark: watermark, pane: pane))
    }

    private func textFile(_ session: Session, key: String?) -> String {
        WatermarkStorage.renderedTextURL(sessionID: session.id, paneKey: key).path
    }

    func testAPaneOverrideNeedsThatPaneToExist() throws {
        let server = makeServer()
        let (_, session) = try makeSession(split: false)
        let label = BackgroundWatermark(kind: .text, text: "PEER")

        XCTAssertEqual(set(server, session, label, pane: .right).error, "session has no split pane")
        XCTAssertEqual(set(server, session, label, pane: .scratch).error, "session has no scratch terminal")
        XCTAssertTrue(session.paneBackgrounds.isEmpty)
        XCTAssertTrue(set(server, session, label, pane: .left).ok)
        XCTAssertEqual(session.paneBackgrounds.left, label)
    }

    func testAPaneOverrideRendersToItsOwnFileAndLeavesTheDefaultAlone() throws {
        let server = makeServer()
        let (_, session) = try makeSession(split: true)
        let rightKey = try XCTUnwrap(session.backgroundFileKey(for: .right))

        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "PEER"), pane: .right).ok)

        XCTAssertTrue(FileManager.default.fileExists(atPath: textFile(session, key: rightKey)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: textFile(session, key: nil)))
        XCTAssertNil(session.backgroundWatermark)
    }

    func testADefaultChangeReappliesOnlyInheritingPanes() throws {
        let server = makeServer()
        let (_, session) = try makeSession(split: true)
        let left = try XCTUnwrap(session.surface as? GhosttySurfaceView)
        let right = try XCTUnwrap(session.splitSurface as? GhosttySurfaceView)
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .color, colorHex: "#102030"), pane: .right).ok)
        left.oscBackgroundColorHex = "#abcdef"
        right.oscBackgroundColorHex = "#abcdef"

        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .color, colorHex: "#201414")).ok)

        XCTAssertNil(left.oscBackgroundColorHex)
        XCTAssertEqual(right.oscBackgroundColorHex, "#abcdef")
    }

    func testAPaneTextFileGoesWithItsSplit() throws {
        let server = makeServer()
        let (store, session) = try makeSession(split: true)
        let rightKey = try XCTUnwrap(session.backgroundFileKey(for: .right))
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "PEER"), pane: .right).ok)

        store.closeSplit(session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: textFile(session, key: rightKey)))
    }

    func testPromotionKeepsTheSurvivorsFileAndDropsTheExitingOnes() throws {
        let server = makeServer()
        let (store, session) = try makeSession(split: true)
        let leftKey = session.paneIdentity.uuidString
        let rightKey = try XCTUnwrap(session.backgroundFileKey(for: .right))
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "DRIVER"), pane: .left).ok)
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "PEER"), pane: .right).ok)

        store.closePrimaryPane(session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: textFile(session, key: leftKey)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: textFile(session, key: rightKey)))
        XCTAssertEqual(session.backgroundFileKey(for: .left), rightKey)
    }

    func testAScratchTextFileGoesWithTheScratch() throws {
        let server = makeServer()
        let (store, session) = try makeSession(split: false)
        _ = addScratch(to: session)
        XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "SCRATCH"), pane: .scratch).ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: textFile(session, key: "scratch")))

        XCTAssertTrue(store.closeScratch(session.id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: textFile(session, key: "scratch")))
    }

    func testRepeatedLabelledSplitsLeaveNoTextFilesBehind() throws {
        let server = makeServer()
        let (store, session) = try makeSession(split: false)
        for _ in 0..<3 {
            store.toggleSplit(session.id)
            let right = realizedView(session: session)
            right.isSplitPane = true
            session.splitSurface = right
            XCTAssertTrue(set(server, session, BackgroundWatermark(kind: .text, text: "PEER"), pane: .right).ok)
            store.closeSplit(session.id)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: WatermarkStorage.directoryURL().path)
        XCTAssertFalse(names.contains { $0.hasPrefix(session.id.uuidString) })
    }
}
