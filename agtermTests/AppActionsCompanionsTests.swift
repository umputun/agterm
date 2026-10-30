import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppActionsCompanionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var huds: HudRecorder!
    private var duplicator: RefusingDuplicator!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-companion-actions-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
        huds = HudRecorder()
        duplicator = RefusingDuplicator()
        actions.remoteAttacher = huds
        actions.companionDuplicator = duplicator
    }

    override func tearDown() async throws {
        actions = nil
        library = nil
        huds = nil
        duplicator = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    // a refusal went only to the notification banner, which a user with banners hidden never sees
    func testARefusedDuplicateShowsTheReasonInATimedHudOverTheSession() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let windowID = try XCTUnwrap(library.windowID(for: store))

        actions.duplicateAsCompanion(session.id, in: store)

        XCTAssertEqual(duplicator.requests, [session.id])
        XCTAssertEqual(huds.opened.count, 1)
        let opened = try XCTUnwrap(huds.opened.first)
        XCTAssertEqual(opened.session, session.id.uuidString)
        XCTAssertEqual(opened.window, windowID.uuidString)
        XCTAssertTrue(opened.spec.message.contains(RefusingDuplicator.reason), opened.spec.message)
        XCTAssertEqual(opened.spec.hideAfter, AppActions.remoteAttachErrorSeconds)
    }
}

private final class RefusingDuplicator: CompanionDuplicating {
    static let reason = "right pane: the foreground program cannot be copied; nothing was created"
    private(set) var requests: [UUID] = []

    func duplicateCompanion(of id: UUID, in _: AppStore, select _: Bool) -> Result<Session, CompanionDuplicateFailure> {
        requests.append(id)
        return .failure(CompanionDuplicateFailure(message: Self.reason))
    }
}

private final class HudRecorder: RemoteAttaching {
    struct Opened {
        let session: String?
        let window: String?
        let spec: HudSpec
    }

    private(set) var opened: [Opened] = []

    func remoteTree(host _: String?) async -> ControlResponse { ControlResponse(ok: false, error: "not scripted") }

    func attachRemoteSession(host _: String, session _: String, window _: String?) async -> ControlResponse {
        ControlResponse(ok: false, error: "not scripted")
    }

    func createRemoteCompanion(_: RemoteCompanionRequest, of _: UUID, in _: AppStore, select _: Bool,
                               progress _: (String) -> Void) async -> ControlResponse {
        ControlResponse(ok: false, error: "not scripted")
    }

    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        opened.append(Opened(session: target, window: window, spec: spec))
        return ControlResponse(ok: true)
    }

    func closeHud(_: String?, window _: String?) -> ControlResponse { ControlResponse(ok: true) }

    func hudGeneration(session _: String) -> Int? { opened.isEmpty ? nil : opened.count }
}
