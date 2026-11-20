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
        func attachCommand(host: String, pane: CatalogPane, claim _: Bool) -> String { "attach \(host) \(pane.daemon)" }
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
        var undoID: String?
        var losesReplies = false

        func run(_ argv: [String]) -> (Int32, String) {
            let line = (argv.last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
            lines.append(line)
            expectation?.fulfill()
            if losesReplies { return (255, "") }
            let opID = line.range(of: "--op-id ").map { String(line[$0.upperBound...].prefix(36)) } ?? ""
            var result = ControlResult()
            result.receipt = CatalogReceipt(opID: opID, epoch: "e1", outcome: .applied, rev: 1)
            if let undoID, line.contains("--undoable") {
                result.undoable = true
                result.undoID = undoID
            }
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

    private func open(_ sessions: [CatalogSession], withEmptyWorkspace: Bool = false, spare: [CatalogSession] = [],
                      recent: [ControlRecentItem]? = nil) {
        var workspaces = [CatalogWorkspace(id: workspaceID, name: "main", sessions: sessions)]
        if withEmptyWorkspace || !spare.isEmpty { workspaces.append(CatalogWorkspace(id: emptyWorkspaceID, name: "spare", sessions: spare)) }
        _ = mirror.receive(.snapshot(CatalogSnapshot(epoch: "e1", rev: 0, catalogID: UUID(),
                                                     versions: CatalogVersions(server: "1", protocolVersion: 1, catalog: 1),
                                                     workspaces: workspaces, recent: recent)))
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

    func testAMovedCompanionGoesToTheServerAtItsIndexPastDetachedRowsAndMovesHereOnlyWithTheCatalog() throws {
        let first = catalogSession(), second = catalogSession()
        let companion = catalogSession(parent: first.id)
        let detached = catalogSession(parent: second.id), resident = catalogSession(parent: second.id)
        open([first, companion, second, detached, resident])
        mirror.detach(sessions: [detached.id])
        let row = try XCTUnwrap(store.session(withID: companion.id))

        actions.moveCompanion(companion.id, under: second.id, at: 0, in: store)
        try sent(1)
        settle()

        XCTAssertTrue(runner.lines[0].contains("session move --target \(companion.id.uuidString) --parent \(second.id.uuidString) --index 1"),
                      runner.lines[0])
        XCTAssertEqual(row.parentID, first.id, "nothing moves here before the catalog reports it")
        var moved = companion.fields
        moved.parent = second.id
        serverApplies(.sessionChanged(moved), .sessionOrder([first.id, second.id, detached.id, companion.id, resident.id], workspace: workspaceID))
        XCTAssertEqual(row.parentID, second.id)
        XCTAssertEqual(store.companions(of: second.id).map(\.id), [companion.id, resident.id])
    }

    func testASessionDroppedIntoAnAllDetachedRootGoesToTheOwnersRootByID() throws {
        let rootID = UUID()
        let moving = catalogSession(), detached = catalogSession()
        openWithRoot(rootID, main: [moving], root: [detached])
        mirror.detach(sessions: [detached.id])
        XCTAssertEqual(store.rootWorkspace?.id, rootID)

        XCTAssertTrue(dropIntoRootGap(moving.id, at: 0))
        try sent(1)

        XCTAssertTrue(runner.lines[0].contains("session move --target \(moving.id.uuidString) "), runner.lines[0])
        XCTAssertTrue(runner.lines[0].hasSuffix("-- \(rootID.uuidString)"), runner.lines[0])
    }

    func testASessionDroppedAfterAVisibleRootRowIsPlacedAfterItPastDetachedRows() throws {
        let rootID = UUID()
        let moving = catalogSession(), detached = catalogSession(), visible = catalogSession()
        openWithRoot(rootID, main: [moving], root: [detached, visible])
        mirror.detach(sessions: [detached.id])

        XCTAssertTrue(dropIntoRootGap(moving.id, at: 1))
        try sent(1)

        XCTAssertTrue(runner.lines[0].contains("session move --target \(moving.id.uuidString) --after \(visible.id.uuidString)"),
                      runner.lines[0])
    }

    func testMoveToShowsTopLevelSessionsDisabledForAnOwnerWithOneWorkspaceAndNoRoot() throws {
        let entry = catalogSession()
        open([entry])
        let (outline, coordinator) = mountSidebar()
        store.setSidebarSelection([entry.id])
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == entry.id })

        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "Move to" }?.submenu, "\(menu.items.map(\.title))")
        XCTAssertEqual(submenu.items.map(\.title), [ControlWorkspaceNode.rootLabel])
        XCTAssertFalse(submenu.items[0].isEnabled)
    }

    func testABatchMoveToGoesToTheServerAsOneRequestWithEveryTarget() throws {
        let rootID = UUID()
        let resident = catalogSession(), other = catalogSession(), named = catalogSession()
        openWithRoot(rootID, main: [named], root: [resident, other])
        let (outline, coordinator) = mountSidebar()
        store.setSidebarSelection([resident.id, named.id])
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == resident.id })
        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "Move to" }?.submenu, "\(menu.items.map(\.title))")
        let item = try XCTUnwrap(submenu.items.first { $0.title == ControlWorkspaceNode.rootLabel })

        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1, "\(runner.lines)")
        XCTAssertTrue(runner.lines[0].contains("session move --target \(resident.id.uuidString) --target \(named.id.uuidString) "),
                      runner.lines[0])
        XCTAssertTrue(runner.lines[0].hasSuffix("-- \(rootID.uuidString)"), runner.lines[0])
    }

    func testALoneCompanionInARootlessOwnerGetsNoMoveTo() throws {
        let parent = catalogSession()
        let companion = catalogSession(parent: parent.id)
        open([parent, companion])
        let (outline, coordinator) = mountSidebar()
        outline.expandItem(nil, expandChildren: true)
        store.setSidebarSelection([companion.id])
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == companion.id })

        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        XCTAssertFalse(menu.items.contains { $0.title == "Move to" }, "\(menu.items.map(\.title))")
    }

    func testMoveToShowsTopLevelSessionsDisabledForAnOwnerWithoutARoot() throws {
        let entry = catalogSession()
        open([entry], withEmptyWorkspace: true)
        let (outline, coordinator) = mountSidebar()
        store.setSidebarSelection([entry.id])
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == entry.id })

        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "Move to" }?.submenu, "\(menu.items.map(\.title))")
        XCTAssertEqual(submenu.items.map(\.title), [ControlWorkspaceNode.rootLabel, "spare"])
        XCTAssertFalse(submenu.items[0].isEnabled)
        XCTAssertTrue(submenu.items[1].isEnabled)
    }

    private func openWithRoot(_ rootID: UUID, main: [CatalogSession], root: [CatalogSession]) {
        let workspaces = [CatalogWorkspace(id: workspaceID, name: "main", sessions: main),
                          CatalogWorkspace(id: rootID, name: "", root: true, sessions: root)]
        _ = mirror.receive(.snapshot(CatalogSnapshot(epoch: "e1", rev: 0, catalogID: UUID(),
                                                     versions: CatalogVersions(server: "1", protocolVersion: 1, catalog: 1),
                                                     workspaces: workspaces)))
    }

    private func mountSidebar() -> (NSOutlineView, WorkspaceSidebar.Coordinator) {
        let outline = NSOutlineView()
        let coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        scroll.documentView = outline
        window.contentView = scroll
        addTeardownBlock { window.orderOut(nil) }
        coordinator.outlineView = outline
        coordinator.rebuildAndReload()
        return (outline, coordinator)
    }

    private func dropIntoRootGap(_ id: UUID, at slot: Int) -> Bool {
        let (outline, coordinator) = mountSidebar()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agterm-remote-drop-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(id.uuidString, forType: sessionPasteboardType)
        let info = SidebarDrag(pasteboard, over: outline)
        guard coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: slot) == .move else { return false }
        return coordinator.outlineView(outline, acceptDrop: info, item: nil, childIndex: slot)
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

    func testTerminatingSessionsOnAServerKeepingRecentIsOneUndoableClose() throws {
        let first = catalogSession(), second = catalogSession()
        open([first, second], recent: [])
        runner.undoID = "u1"

        _ = close([first.id, second.id], answering: .terminate)
        try sent(1)
        settle()

        XCTAssertEqual(runner.lines.count, 1)
        XCTAssertTrue(runner.lines[0].contains("session close --target \(first.id.uuidString) --target \(second.id.uuidString) --undoable"),
                      runner.lines[0])
        XCTAssertEqual(remote.undoIDs, ["u1"])
        assertClosedNothingLocally()
    }

    func testUndoAsksTheServerOnceAndALostReplyIsNotSentAgain() throws {
        let entry = catalogSession()
        open([entry], recent: [])
        runner.undoID = "u1"
        _ = close([entry.id], answering: .terminate)
        try sent(1)
        settle()
        runner.losesReplies = true

        XCTAssertTrue(actions.undoRemoteClose(in: store))
        try sent(2)
        settle()

        XCTAssertTrue(runner.lines[1].contains("session undo --target u1"), runner.lines[1])
        XCTAssertFalse(actions.undoRemoteClose(in: store))
        settle()
        XCTAssertEqual(runner.lines.filter { $0.contains("session undo") }.count, 1)
    }

    func testTheRecentListIsTheServersWhileConnectedAndEmptyWhileNot() {
        library.frontmostWindowID = library.windowID(for: store)
        let item = ControlRecentItem(id: "r1", kind: "session", title: "a", subtitle: nil, closedAt: 1, workspaceID: "w",
                                     sessionIDs: ["s"])
        open([catalogSession()])
        XCTAssertNil(actions.serverRecentItems)

        open([catalogSession()], recent: [item])
        XCTAssertEqual(actions.serverRecentItems, [item])

        mirror.connectionLost("gone")
        XCTAssertEqual(actions.serverRecentItems, [])
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

    func testTheOnlyNamedWorkspaceOfAnOwnerWithARootOffersTerminate() {
        openWithRoot(UUID(), main: [catalogSession()], root: [])

        let asked = closeWorkspace(workspaceID, answering: .cancel)
        settle()

        XCTAssertEqual(asked.calls.count, 1)
        XCTAssertNil(asked.calls.first?.blocked)
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

    func testNewTopLevelSessionInARemoteWindowAsksTheServerForItsRoot() throws {
        let entry = catalogSession()
        let rootID = UUID()
        openWithRoot(rootID, main: [entry], root: [])
        _ = store.selectSession(entry.id)

        actions.newRootSession()
        try sent(1)

        XCTAssertTrue(runner.lines[0].contains("session new --workspace \(rootID.uuidString)"), runner.lines[0])
        XCTAssertEqual(shownIDs(), [entry.id])
    }

    func testNewTopLevelSessionAsksNothingOfAServerWithoutARoot() throws {
        let entry = catalogSession()
        open([entry])
        _ = store.selectSession(entry.id)

        actions.newRootSession()
        settle()

        XCTAssertTrue(runner.lines.isEmpty, "\(runner.lines)")
        XCTAssertEqual(shownIDs(), [entry.id])
    }

    func testTheFocusEditorListsTheTopLevelSessionsDisabledForAServerWithoutARoot() throws {
        open([catalogSession()])

        let rows = actions.paletteFocusEditor()

        XCTAssertEqual(rows.first?.title, "Top-Level Sessions")
        XCTAssertEqual(rows.first?.isEnabled(), false)
        XCTAssertEqual(rows.first?.runIfEnabled(), false)
        XCTAssertEqual(rows.dropFirst().map(\.id), [workspaceID.uuidString])
    }

    func testTheFocusEditorListsTheServersRootLikeAnyContainer() throws {
        let rootID = UUID()
        openWithRoot(rootID, main: [catalogSession()], root: [])

        let rows = actions.paletteFocusEditor()

        XCTAssertEqual(rows.map(\.id), [rootID.uuidString, workspaceID.uuidString])
        XCTAssertEqual(rows.first?.isEnabled(), true)
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
