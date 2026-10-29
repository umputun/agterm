import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerSessionCloseTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-session-close-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            server = ControlServer(
                library: library,
                actions: AppActions(library: library),
                settingsModel: settingsModel,
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            library.finalizeAllPendingCloses()
            server = nil
            settingsModel = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testUndoableSingleCloseIsSoftWhileGraceUndoIsOn() async throws {
        let (store, session) = try addSession()

        let response = await close(session.id.uuidString, undoable: true)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString, undoable: true,
                                                                                 closed: [session.id.uuidString])))
        XCTAssertNil(store.session(withID: session.id))
        XCTAssertTrue(store.undoPendingClose())
        XCTAssertTrue(store.session(withID: session.id) === session)
    }

    func testUndoableSingleCloseIsHardAndSaysSoWhenGraceUndoIsOff() async throws {
        settingsModel.setCloseGraceUndoEnabled(false)
        let (store, session) = try addSession()

        let response = await close(session.id.uuidString, undoable: true)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString, undoable: false,
                                                                                 closed: [session.id.uuidString])))
        XCTAssertNil(store.session(withID: session.id))
        XCTAssertNil(store.pendingCloseSession(withID: session.id))
    }

    func testPlainSingleCloseStaysHardWithoutAnUndoableAnswer() async throws {
        let (store, session) = try addSession()

        let response = await close(session.id.uuidString)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString, closed: [session.id.uuidString])))
        XCTAssertNil(store.session(withID: session.id))
        XCTAssertNil(store.pendingCloseSession(withID: session.id))
    }

    func testABatchDeduplicatedToOneTargetHonorsUndoable() async throws {
        let (store, session) = try addSession()
        let id = session.id.uuidString

        let response = await close(id, targets: [id, id], undoable: true)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(id: id, undoable: true, closed: [id])))
        XCTAssertTrue(store.pendingCloseSession(withID: session.id) === session)
    }

    func testUndoableBatchReportsWhetherTheGroupStayedUndoable() async throws {
        let (store, first) = try addSession()
        let (_, second) = try addSession()
        let (_, third) = try addSession()
        let (_, fourth) = try addSession()

        let soft = await close(first.id.uuidString, targets: [first.id.uuidString, second.id.uuidString], undoable: true)
        settingsModel.setCloseGraceUndoEnabled(false)
        let hard = await close(third.id.uuidString, targets: [third.id.uuidString, fourth.id.uuidString], undoable: true)

        XCTAssertEqual(soft, ControlResponse(ok: true, result: ControlResult(affected: 2, undoable: true,
                                                                             closed: [first.id.uuidString, second.id.uuidString])))
        XCTAssertEqual(hard, ControlResponse(ok: true, result: ControlResult(affected: 2, undoable: false,
                                                                             closed: [third.id.uuidString, fourth.id.uuidString])))
        XCTAssertNil(store.session(withID: third.id))
        XCTAssertNil(store.session(withID: fourth.id))
        XCTAssertNil(store.pendingCloseSession(withID: third.id))
        XCTAssertTrue(store.undoPendingClose())
        XCTAssertTrue(store.session(withID: first.id) === first)
        XCTAssertTrue(store.session(withID: second.id) === second)
    }

    private func close(_ target: String, targets: [String]? = nil, undoable: Bool? = nil) async -> ControlResponse? {
        await ControlDispatcher(actions: server).dispatch(ControlRequest(
            cmd: .sessionClose, target: target, args: ControlArgs(targets: targets, undoable: undoable)))
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory())))
    }
}
