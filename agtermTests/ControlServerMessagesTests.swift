import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the message bus through the real `ControlServer` adapter: address resolution across
/// windows, broadcast scope and identity agreement, which a `MockControlActions` cannot exercise.
@MainActor
final class ControlServerMessagesTests: XCTestCase {
    private final class LiveSurface: TerminalSurface {
        let paneToken: String
        var isRealized = true
        init(_ pane: UUID) { paneToken = pane.uuidString }
        func teardown() {}
        func promoteToPrimaryPane() {}
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var touched: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-messages-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        server = ControlServer(
            library: library, actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    override func tearDown() async throws {
        touched.forEach { MessageBus.shared.dispose(pane: $0) }
        touched = []
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func liveSession(in store: AppStore, workspace: UUID? = nil, remote: String? = nil) throws -> Session {
        let owner = try XCTUnwrap(workspace ?? store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: "/tmp", remoteHost: remote))
        session.surface = LiveSurface(session.paneIdentity)
        touched.append(session.paneIdentity)
        return session
    }

    private func address(_ session: Session, _ pane: UUID? = nil) -> String {
        MessageAddress.canonical(session: session.id, pane: pane ?? session.paneIdentity)
    }

    private func send(_ args: ControlArgs) async -> ControlResponse? {
        await ControlDispatcher(actions: server).dispatch(ControlRequest(cmd: .msgSend, args: args))
    }

    private func otherStore() throws -> AppStore {
        try XCTUnwrap(library.store(for: library.newWindow(name: "other").id))
    }

    func testBroadcastReachesEveryOpenWindowAndSkipsTheSenderAndRemoteRows() async throws {
        let first = try XCTUnwrap(library.activeStore)
        let sender = try liveSession(in: first)
        let near = try liveSession(in: first)
        _ = try liveSession(in: first, remote: "buildbox")
        let far = try liveSession(in: try otherStore())

        let response = await send(ControlArgs(body: "hi", all: true, identity: address(sender)))

        XCTAssertEqual(Set(response?.result?.delivered ?? []), [address(near), address(far)])
        XCTAssertEqual(MessageBus.shared.pending(for: sender.paneIdentity), 0)
    }

    func testAnAnonymousBroadcastReachesEveryPane() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let panes = try (0..<2).map { _ in try liveSession(in: store) }

        let response = await send(ControlArgs(body: "hi", all: true))

        XCTAssertEqual(Set(response?.result?.delivered ?? []), Set(panes.map { address($0) }))
    }

    func testWorkspaceNarrowsTheBroadcast() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let inside = try liveSession(in: store)
        let other = store.addWorkspace(name: "elsewhere")
        _ = try liveSession(in: store, workspace: other.id)
        let workspace = try XCTUnwrap(store.workspace(forSession: inside.id)).id

        let response = await send(ControlArgs(workspace: workspace.uuidString, body: "hi", all: true))

        XCTAssertEqual(response?.result?.delivered, [address(inside)])
    }

    func testAliasesOfOnePaneAreDeliveredOnce() async throws {
        let session = try liveSession(in: try XCTUnwrap(library.activeStore))

        let response = await send(ControlArgs(body: "hi", recipients: ["\(session.id.uuidString):left", address(session)]))

        XCTAssertEqual(response?.result?.delivered, [address(session)])
        XCTAssertEqual(MessageBus.shared.pending(for: session.paneIdentity), 1)
    }

    func testTheScratchPaneIsARecipientAndAnIdentity() async throws {
        let session = try liveSession(in: try XCTUnwrap(library.activeStore))
        let scratch = UUID()
        session.scratchSurface = LiveSurface(scratch)
        touched.append(scratch)

        let sent = await send(ControlArgs(body: "hi", recipients: ["\(session.id.uuidString):scratch"]))
        let read = await ControlDispatcher(actions: server).dispatch(
            ControlRequest(cmd: .msgRead, args: ControlArgs(identity: address(session, scratch))))

        XCTAssertEqual(sent?.result?.delivered, [address(session, scratch)])
        XCTAssertEqual(read?.result?.messages?.map(\.body), ["hi"])
    }

    func testASplitHiddenSinceLaunchIsNotALivePane() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try liveSession(in: store)
        store.setSplitVisibility(session.id, shown: true)
        store.setSplitVisibility(session.id, shown: false)
        let split = try XCTUnwrap(session.splitPaneIdentity)

        let sent = await send(ControlArgs(body: "hi", recipients: ["\(session.id.uuidString):right"]))
        let asSplit = await send(ControlArgs(body: "hi", all: true, identity: address(session, split)))

        XCTAssertEqual(sent?.result?.rejected, [MessageRejection(address: "\(session.id.uuidString):right", reason: .unknownPane)])
        XCTAssertEqual(asSplit?.error, "pane \(split.uuidString) is not a live pane of session \(session.id.uuidString)")
    }

    func testAnIdentityNamingAnotherSessionsPaneIsRefusedOnEveryCommand() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let mine = try liveSession(in: store)
        let theirs = try liveSession(in: store)
        let forged = MessageAddress.canonical(session: mine.id, pane: theirs.paneIdentity)
        let expected = "pane \(theirs.paneIdentity.uuidString) is not a live pane of session \(mine.id.uuidString)"

        for cmd in [Command.msgSend, .msgRead, .msgAck] {
            let response = await ControlDispatcher(actions: server).dispatch(ControlRequest(
                cmd: cmd, args: ControlArgs(body: "hi", all: true, identity: forged, ids: [UUID().uuidString])))
            XCTAssertEqual(response?.error, expected, cmd.rawValue)
        }
        XCTAssertEqual(MessageBus.shared.pending(for: mine.paneIdentity), 0)
    }

    func testAStaleIdentityFailsAndNeverSendsAnonymously() async throws {
        let target = try liveSession(in: try XCTUnwrap(library.activeStore))
        let stale = MessageAddress.canonical(session: UUID(), pane: UUID())

        let response = await send(ControlArgs(body: "hi", recipients: [address(target)], identity: stale))

        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(MessageBus.shared.pending(for: target.paneIdentity), 0)
    }

    func testClosingOrDeletingAWindowDisposesItsMail() async throws {
        for delete in [false, true] {
            let windowID = library.newWindow(name: "doomed").id
            let session = try liveSession(in: try XCTUnwrap(library.store(for: windowID)))
            _ = await send(ControlArgs(body: "hi", recipients: [address(session)]))
            XCTAssertEqual(MessageBus.shared.pending(for: session.paneIdentity), 1)

            if delete { library.removeWindow(windowID) } else { library.closeWindow(windowID) }

            XCTAssertEqual(MessageBus.shared.pending(for: session.paneIdentity), 0, delete ? "delete" : "close")
        }
    }

    func testTheMessageEventCarriesWindowAndWorkspace() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try liveSession(in: store)
        let dispatcher = ControlDispatcher(actions: server)
        let bootstrap = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead))
        let batch = try XCTUnwrap(bootstrap?.result?.events)

        _ = await send(ControlArgs(body: "hi", recipients: [address(session)]))
        let read = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead, args: ControlArgs(
            after: String(batch.next), run: batch.run.uuidString, kinds: ["message"])))

        let event = try XCTUnwrap(read?.result?.events?.items.first)
        XCTAssertEqual(event.kind, .message)
        XCTAssertEqual(event.session, session.id.uuidString)
        XCTAssertEqual(event.workspace, store.workspace(forSession: session.id)?.id.uuidString)
        XCTAssertNotNil(event.window)
        XCTAssertEqual(event.payload.paneID, session.paneIdentity.uuidString)
    }
}
