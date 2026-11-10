import SwiftUI
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppActionsRemoteCatalogTests: XCTestCase {
    private var directory: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var store: AppStore!
    private var mirror: RemoteCatalogMirror!
    private var remote: RemoteCatalogActions!
    private var recentClosedBefore = 0
    private let effects = Effects()
    private let runner = Recorder()
    private let workspaceID = UUID()
    private let emptyWorkspaceID = UUID()
    private static let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")

    private struct NotSent: Error {}

    private final class Effects: RemoteCatalogEffects {
        func attachCommand(host: String, pane: CatalogPane) -> String { "attach \(host) \(pane.daemon)" }
        func catalogRowAdded(_: Session) {}
        func catalogRowRemoved(_: UUID) {}
        func catalogRowEnded(_: UUID) {}
        func catalogPaneNeedsAttach(_: UUID, session _: UUID) {}
        func catalogBound(_: UUID) -> Bool { true }
        func catalogStateChanged(_: RemoteCatalogMirror.State) {}
    }

    @MainActor
    private final class Recorder {
        var lines: [String] = []
        var expectation: XCTestExpectation?

        func run(_ argv: [String]) -> (Int32, String) {
            let line = (argv.last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
            lines.append(line)
            expectation?.fulfill()
            let opID = line.range(of: "--op-id ").map { String(line[$0.upperBound...].prefix(36)) } ?? ""
            var result = ControlResult()
            result.receipt = CatalogReceipt(opID: opID, epoch: "e1", outcome: .applied, rev: 1)
            let reply = (try? JSONEncoder().encode(ControlResponse(ok: true, result: result))) ?? Data()
            return (0, String(decoding: reply, as: UTF8.self))
        }
    }

    @MainActor
    private final class Asked {
        var calls: [(name: String, host: String, blocked: String?)] = []

        func answer(_ choice: AppActions.RemoteCloseChoice) -> AppActions.RemoteCloseChooser {
            { [self] name, host, blocked in
                calls.append((name, host, blocked))
                return choice
            }
        }
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-remote-close-\(UUID().uuidString)")
        library = WindowLibrary(directory: directory)
        let window = library.newRemoteWindow(host: "box")
        store = try XCTUnwrap(library.store(for: window.id))
        mirror = RemoteCatalogMirror(host: "box", store: store, effects: effects, viewState: RemoteWindowViewState())
        let runner = runner
        remote = RemoteCatalogActions(mirror: mirror, runner: { runner.run($0) })
        store.remoteActions = remote
        actions = AppActions(library: library)
        recentClosedBefore = library.recentClosedItems.count
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func catalogSession(_ id: UUID = UUID(), parent: UUID? = nil, ended: Bool = false, cwd: String = "/srv") -> CatalogSession {
        let pane = CatalogPane(identity: UUID(), daemon: "agterm-\(id.uuidString)", endpoint: Self.endpoint)
        return CatalogSession(fields: CatalogSessionFields(id: id, name: "s-\(id.uuidString.prefix(4))", parent: parent, cwd: cwd,
                                                           primary: pane.identity, axis: nil, shown: false,
                                                           lifecycle: ended ? .ended : .live),
                              panes: ended ? [] : [pane])
    }

    private func open(_ sessions: [CatalogSession], withEmptyWorkspace: Bool = false, spare: [CatalogSession] = []) {
        var workspaces = [CatalogWorkspace(id: workspaceID, name: "main", sessions: sessions)]
        if withEmptyWorkspace || !spare.isEmpty { workspaces.append(CatalogWorkspace(id: emptyWorkspaceID, name: "spare", sessions: spare)) }
        _ = mirror.receive(.snapshot(CatalogSnapshot(epoch: "e1", rev: 0, catalogID: UUID(),
                                                     versions: CatalogVersions(server: "1", protocolVersion: 1, catalog: 1),
                                                     workspaces: workspaces)))
    }

    private func serverApplies(_ changes: CatalogChange...) {
        for (index, change) in changes.enumerated() {
            _ = mirror.receive(.delta(epoch: "e1", rev: index + 1, change: change))
        }
    }

    private func sent(_ count: Int) throws {
        guard runner.lines.count < count else { return }
        let expectation = XCTestExpectation(description: "\(count) server command(s)")
        expectation.expectedFulfillmentCount = count - runner.lines.count
        runner.expectation = expectation
        defer { runner.expectation = nil }
        guard XCTWaiter().wait(for: [expectation], timeout: 5) == .completed else { throw NotSent() }
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func close(_ ids: [UUID], answering choice: AppActions.RemoteCloseChoice) -> Asked {
        let asked = Asked()
        XCTAssertTrue(actions.closeRemote(ids, in: store, choose: asked.answer(choice)))
        return asked
    }

    private func closeWorkspace(_ id: UUID, answering choice: AppActions.RemoteCloseChoice) -> Asked {
        let asked = Asked()
        XCTAssertTrue(actions.closeRemoteWorkspace(id, in: store, choose: asked.answer(choice)))
        return asked
    }

    private func shownIDs() -> Set<UUID> { Set(store.workspaces.flatMap(\.sessions).map(\.id)) }

    private func hasWorkspace(_ id: UUID) -> Bool { store.workspaces.contains { $0.id == id } }

    private func assertClosedNothingLocally(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(store.pendingCloseSummary, file: file, line: line)
        XCTAssertEqual(library.recentClosedItems.count, recentClosedBefore, file: file, line: line)
    }

    func testDetachingASessionHidesItAndSendsNothing() {
        let entry = catalogSession()
        open([entry])

        let asked = close([entry.id], answering: .detach)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertEqual(asked.calls.first?.host, "box")
        XCTAssertNil(asked.calls.first?.blocked)
        XCTAssertFalse(shownIDs().contains(entry.id))
        XCTAssertEqual(mirror.detachedItems.map(\.id), [entry.id])
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testTerminatingASessionSendsOneCloseAndTheRowLeavesWithTheServersRemoval() throws {
        let entry = catalogSession()
        open([entry])

        _ = close([entry.id], answering: .terminate)
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("session close --target \(entry.id.uuidString)"))
        XCTAssertTrue(shownIDs().contains(entry.id))
        XCTAssertTrue(mirror.detachedItems.isEmpty)
        serverApplies(.sessionRemoved(entry.id))
        XCTAssertFalse(shownIDs().contains(entry.id))
        assertClosedNothingLocally()
    }

    func testCancellingASessionCloseChangesNothing() {
        let entry = catalogSession()
        open([entry])
        let selected = store.selectedSessionID

        let asked = close([entry.id], answering: .cancel)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertTrue(shownIDs().contains(entry.id))
        XCTAssertTrue(mirror.detachedItems.isEmpty)
        XCTAssertTrue(runner.lines.isEmpty)
        XCTAssertEqual(store.selectedSessionID, selected)
        assertClosedNothingLocally()
    }

    func testDetachingACompanionGroupAsksOnceAndHidesItWhole() {
        let parent = catalogSession()
        let companion = catalogSession(parent: parent.id)
        open([parent, companion])

        let asked = close([parent.id, companion.id], answering: .detach)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertTrue(shownIDs().isDisjoint(with: [parent.id, companion.id]))
        XCTAssertEqual(mirror.detachedItems.map(\.id), [parent.id])
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testTerminatingACompanionGroupSendsOnlyTheParentsCloseAndTheGroupLeavesWithTheServersRemoval() throws {
        let parent = catalogSession()
        let companion = catalogSession(parent: parent.id)
        open([parent, companion])

        _ = close([parent.id, companion.id], answering: .terminate)
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("session close --target \(parent.id.uuidString)"))
        XCTAssertTrue(shownIDs().isSuperset(of: [parent.id, companion.id]))
        XCTAssertTrue(mirror.detachedItems.isEmpty)
        serverApplies(.sessionRemoved(parent.id), .sessionRemoved(companion.id))
        XCTAssertTrue(shownIDs().isDisjoint(with: [parent.id, companion.id]))
        assertClosedNothingLocally()
    }

    func testCancellingACompanionGroupCloseChangesNothing() {
        let parent = catalogSession()
        let companion = catalogSession(parent: parent.id)
        open([parent, companion])

        let asked = close([parent.id, companion.id], answering: .cancel)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertTrue(shownIDs().isSuperset(of: [parent.id, companion.id]))
        XCTAssertTrue(mirror.detachedItems.isEmpty)
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testDetachingAWorkspaceHidesItAndSendsNothing() {
        let entry = catalogSession()
        open([entry], withEmptyWorkspace: true)

        let asked = closeWorkspace(workspaceID, answering: .detach)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertNil(asked.calls.first?.blocked)
        XCTAssertFalse(hasWorkspace(workspaceID))
        XCTAssertEqual(mirror.detachedItems.map(\.id), [workspaceID])
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testTerminatingAWorkspaceSendsItsDeleteAndItLeavesWithTheServersRemoval() throws {
        let entry = catalogSession()
        open([entry], withEmptyWorkspace: true)

        _ = closeWorkspace(workspaceID, answering: .terminate)
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("workspace delete --target \(workspaceID.uuidString)"))
        XCTAssertTrue(hasWorkspace(workspaceID))
        XCTAssertTrue(mirror.detachedItems.isEmpty)
        serverApplies(.workspaceRemoved(workspaceID))
        XCTAssertFalse(hasWorkspace(workspaceID))
        assertClosedNothingLocally()
    }

    func testCancellingAWorkspaceCloseChangesNothing() {
        let entry = catalogSession()
        open([entry], withEmptyWorkspace: true)

        let asked = closeWorkspace(workspaceID, answering: .cancel)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertTrue(hasWorkspace(workspaceID))
        XCTAssertTrue(shownIDs().contains(entry.id))
        XCTAssertTrue(mirror.detachedItems.isEmpty)
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testDetachingAnEmptyWorkspaceHidesOnlyIt() {
        let entry = catalogSession()
        open([entry], withEmptyWorkspace: true)

        let asked = closeWorkspace(emptyWorkspaceID, answering: .detach)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertFalse(hasWorkspace(emptyWorkspaceID))
        XCTAssertTrue(hasWorkspace(workspaceID))
        XCTAssertEqual(mirror.detachedItems.map(\.id), [emptyWorkspaceID])
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testTerminatingAnEmptyWorkspaceSendsItsDeleteAndItLeavesWithTheServersRemoval() throws {
        let entry = catalogSession()
        open([entry], withEmptyWorkspace: true)

        _ = closeWorkspace(emptyWorkspaceID, answering: .terminate)
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("workspace delete --target \(emptyWorkspaceID.uuidString)"))
        XCTAssertTrue(hasWorkspace(emptyWorkspaceID))
        serverApplies(.workspaceRemoved(emptyWorkspaceID))
        XCTAssertFalse(hasWorkspace(emptyWorkspaceID))
        assertClosedNothingLocally()
    }

    func testCancellingAnEmptyWorkspaceCloseChangesNothing() {
        let entry = catalogSession()
        open([entry], withEmptyWorkspace: true)

        let asked = closeWorkspace(emptyWorkspaceID, answering: .cancel)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertTrue(hasWorkspace(emptyWorkspaceID))
        XCTAssertTrue(mirror.detachedItems.isEmpty)
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testTheOnlyWorkspaceOffersDetachButNotTerminate() {
        let entry = catalogSession()
        open([entry])

        let asked = closeWorkspace(workspaceID, answering: .cancel)
        settle()

        XCTAssertEqual(asked.calls.first?.blocked, "box keeps at least one workspace, so its only one cannot be terminated.")
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testDisconnectedCloseOffersDetachOnlyAndDetachStillWorks() {
        let entry = catalogSession()
        open([entry])
        mirror.connectionLost("gone")

        let asked = close([entry.id], answering: .detach)
        settle()

        XCTAssertEqual(asked.calls.first?.blocked, "Terminate needs a connection to box.")
        XCTAssertEqual(mirror.detachedItems.map(\.id), [entry.id])
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testAnEndedParentWithALiveCompanionStillAsks() {
        let parent = catalogSession(ended: true)
        let companion = catalogSession(parent: parent.id)
        open([parent, companion])

        let asked = close([parent.id], answering: .cancel)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertTrue(runner.lines.isEmpty)
        assertClosedNothingLocally()
    }

    func testAnInertEndedRowClosesWithOneServerRequestAndNoQuestion() throws {
        let entry = catalogSession(ended: true)
        open([entry])

        let asked = close([entry.id], answering: .cancel)
        try sent(1)
        settle()

        XCTAssertTrue(asked.calls.isEmpty)
        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("session close --target \(entry.id.uuidString)"))
        serverApplies(.sessionRemoved(entry.id))
        XCTAssertFalse(shownIDs().contains(entry.id))
        assertClosedNothingLocally()
    }

    func testALocalWindowIsNotARemoteClose() throws {
        let local = library.newWindow()
        let localStore = try XCTUnwrap(library.store(for: local.id))
        let session = try XCTUnwrap(localStore.activeSession)

        let asked = Asked()
        let handled = actions.closeRemote([session.id], in: localStore, choose: asked.answer(.terminate))

        XCTAssertFalse(handled)
        XCTAssertTrue(asked.calls.isEmpty)
        XCTAssertTrue(runner.lines.isEmpty)
    }

    func testNewSessionInARemoteWindowAsksTheServerAndAddsNoRowHere() throws {
        let entry = catalogSession()
        open([entry])
        _ = store.selectSession(entry.id)

        actions.newSession()
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("session new --workspace \(workspaceID.uuidString)"))
        XCTAssertEqual(shownIDs(), [entry.id])
    }

    func testNewSessionInAnotherRemoteWorkspaceTakesThatWorkspacesFolder() throws {
        let selected = catalogSession(cwd: "/srv/selected")
        let other = catalogSession(cwd: "/srv/other")
        open([selected], spare: [other])
        _ = store.selectSession(selected.id)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: directory))
        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.currentSession.rawValue)
        actions.settingsModel = settings

        actions.newRemoteSession(inWorkspace: emptyWorkspaceID, of: store)
        try sent(1)

        XCTAssertTrue(runner.lines[0].contains("session new --workspace \(emptyWorkspaceID.uuidString)"))
        XCTAssertTrue(runner.lines[0].contains("--cwd=/srv/other"))
    }

    func testToggleSplitInARemoteWindowAsksTheServerAndLeavesTheRowUnsplit() throws {
        let entry = catalogSession()
        open([entry])
        _ = store.selectSession(entry.id)

        actions.toggleSplit()
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("session split visibility on --target \(entry.id.uuidString)"))
        XCTAssertEqual(store.session(withID: entry.id)?.hasSplit, false)
    }

    func testMovingASessionInARemoteWindowAsksTheServerAndKeepsItsWorkspaceHere() throws {
        let entry = catalogSession()
        open([entry], withEmptyWorkspace: true)

        actions.moveSession(entry.id, toWorkspace: emptyWorkspaceID)
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("session move --target \(entry.id.uuidString)"))
        XCTAssertTrue(runner.lines[0].contains("-- \(emptyWorkspaceID.uuidString)"))
        XCTAssertEqual(store.sessionLocation(ofSession: entry.id)?.workspace, workspaceID)
    }

    func testAnInlineSidebarRenameInARemoteWindowAsksTheServerAndKeepsTheNameHere() throws {
        let entry = catalogSession()
        open([entry])
        _ = store.selectSession(entry.id)
        let original = try XCTUnwrap(store.session(withID: entry.id)?.displayName)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let host = NSHostingView(rootView: WorkspaceSidebar(store: store, actions: actions).frame(width: 300, height: 400))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        actions.renameActiveSession()
        let deadline = Date(timeIntervalSinceNow: 5)
        while !(window.firstResponder is NSTextView), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.string = "renamed"
        window.makeFirstResponder(nil)
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("session rename --target \(entry.id.uuidString)"))
        XCTAssertTrue(runner.lines[0].hasSuffix("-- renamed"))
        XCTAssertEqual(store.session(withID: entry.id)?.displayName, original)
    }
}
