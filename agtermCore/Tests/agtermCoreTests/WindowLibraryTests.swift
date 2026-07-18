import Foundation
import Testing
@testable import agtermCore

/// Class suite (reference type) so `init`/`deinit` create and tear down a unique temp state
/// directory around each test — no shared on-disk state, no Application Support pollution.
/// `WindowLibrary` is `@MainActor`, so the suite is too.
@MainActor
final class WindowLibraryTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-windows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var indexURL: URL { directory.appendingPathComponent("windows.json") }
    private var legacyURL: URL { directory.appendingPathComponent("workspaces.json") }
    private func windowFileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("windows").appendingPathComponent("\(id.uuidString).json")
    }

    private func writeIndex(_ index: WindowsIndex) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL)
    }

    private func writeWindowFile(_ id: UUID, _ snapshot: Snapshot) throws {
        let store = PersistenceStore(directory: directory.appendingPathComponent("windows"), fileName: "\(id.uuidString).json")
        try store.save(snapshot)
    }

    // MARK: - Seeding

    @Test func freshLibrarySeedsOneWindowWithDefaultTree() {
        let library = WindowLibrary(directory: directory)
        #expect(library.windows.count == 1)
        #expect(library.windows[0].name == "window 1")
        let store = try! #require(library.store(for: library.windows[0].id))
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].name == "workspace 1")
        #expect(store.workspaces[0].sessions.count == 1)
        #expect(library.openIDs() == [library.windows[0].id])
    }

    @Test func windowNameForIDReturnsNameOrEmpty() {
        let library = WindowLibrary(directory: directory)
        #expect(library.windowName(for: library.windows[0].id) == "window 1")
        let work = library.newWindow(name: "work")
        #expect(library.windowName(for: work.id) == "work")
        #expect(library.windowName(for: nil) == "")       // nil id -> empty (the command-context default)
        #expect(library.windowName(for: UUID()) == "")    // unknown id -> empty
    }

    @Test func allOpenSessionsFlattensEverySessionAcrossWindows() {
        let library = WindowLibrary(directory: directory)
        #expect(library.allOpenSessions().count == 1) // the seeded window's one session
        let second = library.newWindow(name: "work")
        let store = try! #require(library.store(for: second.id))
        _ = store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp")
        // two windows: window 1 (1 session) + work (2 sessions) = 3.
        #expect(library.allOpenSessions().count == 3)
    }

    @Test func totalUnseenCountSumsEverySessionAcrossWindows() {
        let library = WindowLibrary(directory: directory)
        #expect(library.totalUnseenCount == 0) // a fresh tree has nothing unseen
        let firstStore = try! #require(library.store(for: library.windows[0].id))
        firstStore.workspaces[0].sessions[0].unseenCount = 2
        let second = library.newWindow(name: "work")
        let secondStore = try! #require(library.store(for: second.id))
        secondStore.workspaces[0].sessions[0].unseenCount = 3
        let extra = try! #require(secondStore.addSession(toWorkspace: secondStore.workspaces[0].id, cwd: "/tmp"))
        extra.unseenCount = 5
        // 2 (window 1) + 3 + 5 (work) = 10 across both open windows.
        #expect(library.totalUnseenCount == 10)
        // closing a window drops its sessions from the roll-up.
        library.closeWindow(second.id)
        #expect(library.totalUnseenCount == 2)
    }

    @Test func closingSessionRecordsAndReopensRecentItem() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let originalWorkspace = store.addWorkspace(name: "project")
        let first = try! #require(store.addSession(toWorkspace: originalWorkspace.id, cwd: "/first", name: "first"))
        let session = try! #require(store.addSession(toWorkspace: originalWorkspace.id, cwd: "/project", name: "api"))
        let last = try! #require(store.addSession(toWorkspace: originalWorkspace.id, cwd: "/last", name: "last"))
        _ = store.addWorkspace(name: "other")

        store.closeSession(session.id)

        let recent = try! #require(library.recentClosedItems.first)
        #expect(recent.kind == .session)
        #expect(recent.title == "api")
        #expect(recent.subtitle == originalWorkspace.name)
        #expect(store.session(withID: session.id) == nil)

        #expect(library.reopenRecentClosed(recent.id))
        let restored = try! #require(store.session(withID: session.id))
        #expect(restored.initialCwd == "/project")
        #expect(restored.customName == "api")
        let restoredWorkspace = try! #require(store.workspaces.first { $0.id == originalWorkspace.id })
        #expect(restoredWorkspace.sessions.map(\.id) == [first.id, session.id, last.id])
        #expect(store.selectedSessionID == session.id)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func reopeningRecentSessionRecreatesMissingOriginalWorkspace() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let originalWorkspace = store.addWorkspace(name: "project")
        let session = try! #require(store.addSession(toWorkspace: originalWorkspace.id, cwd: "/project", name: "api"))

        store.closeSession(session.id)
        let recent = try! #require(library.recentClosedItems.first)
        store.removeWorkspace(originalWorkspace.id)

        #expect(library.reopenRecentClosed(recent.id))
        let restoredWorkspace = try! #require(store.workspaces.first { $0.id == originalWorkspace.id })
        #expect(restoredWorkspace.name == "project")
        #expect(restoredWorkspace.sessions.map(\.id) == [session.id])
        #expect(store.selectedSessionID == session.id)
    }

    @Test func reopeningStaleRecentSessionSelectsExistingSessionInsteadOfDuplicatingID() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let session = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))

        store.closeSession(session.id)
        let recent = try! #require(library.recentClosedItems.first)
        #expect(store.restoreRecentClosed(recent))
        #expect(store.restoreRecentClosed(recent))

        let matching = store.workspaces.flatMap(\.sessions).filter { $0.id == session.id }
        #expect(matching.count == 1)
        #expect(store.selectedSessionID == session.id)
    }

    @Test func closingWorkspaceRecordsAndReopensRecentItem() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let session = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))

        store.removeWorkspace(workspace.id)

        let recent = try! #require(library.recentClosedItems.first)
        #expect(recent.kind == .workspace)
        #expect(recent.title == "project")
        #expect(recent.subtitle == "1 session")
        #expect(store.workspaces.contains { $0.id == workspace.id } == false)

        #expect(library.reopenRecentClosed(recent.id))
        let restoredWorkspace = try! #require(store.workspaces.first { $0.id == workspace.id })
        #expect(restoredWorkspace.name == "project")
        #expect(restoredWorkspace.sessions.map(\.id) == [session.id])
        #expect(store.selectedSessionID == session.id)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func reopeningStaleRecentWorkspaceSelectsExistingWorkspaceInsteadOfDuplicatingIDs() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.addWorkspace(name: "project")
        let session = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/project", name: "api"))

        store.removeWorkspace(workspace.id)
        let recent = try! #require(library.recentClosedItems.first)
        #expect(store.restoreRecentClosed(recent))
        #expect(store.restoreRecentClosed(recent))

        let matchingWorkspaces = store.workspaces.filter { $0.id == workspace.id }
        let matchingSessions = store.workspaces.flatMap(\.sessions).filter { $0.id == session.id }
        #expect(matchingWorkspaces.count == 1)
        #expect(matchingSessions.count == 1)
        #expect(store.selectedSessionID == session.id)
    }

    @Test func reopeningRecentDuringGraceRestoresPendingSessionWithoutRebuildingSnapshot() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.workspaces[0]
        let session = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/grace", name: "grace"))
        let surface = SpySurface()
        session.surface = surface

        #expect(store.softCloseSession(session.id, grace: 60))
        let recent = try! #require(library.recentClosedItems.first)
        #expect(library.reopenRecentClosed(recent.id))

        let restored = try! #require(store.session(withID: session.id))
        #expect(restored === session)
        #expect(surface.teardownCount == 0)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func graceUndoRecordsRecentAndUndoRemovesIt() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.workspaces[0]
        let undone = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/undo", name: "undo"))
        #expect(store.softCloseSession(undone.id, grace: 60))
        #expect(library.recentClosedItems.map(\.title) == ["undo"])
        #expect(store.undoPendingClose())
        #expect(library.recentClosedItems.isEmpty)

        let finalized = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/final", name: "final"))
        #expect(store.softCloseSession(finalized.id, grace: 60))
        store.finalizeAllPendingCloses()

        let recent = try! #require(library.recentClosedItems.first)
        #expect(recent.kind == .session)
        #expect(recent.title == "final")
    }

    @Test func groupedGraceUndoRestoresAllSessionsAndRemovesRecentEntries() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.workspaces[0]
        let first = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/one", name: "one"))
        let second = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/two", name: "two"))

        #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        #expect(Set(library.recentClosedItems.map(\.title)) == ["one", "two"])

        #expect(store.undoPendingClose())

        #expect(store.session(withID: first.id) === first)
        #expect(store.session(withID: second.id) === second)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func reopeningGroupedGraceSessionSelectsTheChosenRecentItem() {
        let library = WindowLibrary(directory: directory)
        let store = try! #require(library.activeStore)
        let workspace = store.workspaces[0]
        let first = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/one", name: "one"))
        let second = try! #require(store.addSession(toWorkspace: workspace.id, cwd: "/two", name: "two"))
        store.selectSession(first.id)
        #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        let chosen = try! #require(library.recentClosedItems.first { $0.session?.snapshot.id == second.id })

        #expect(library.reopenRecentClosed(chosen.id))

        #expect(store.session(withID: first.id) === first)
        #expect(store.session(withID: second.id) === second)
        #expect(store.selectedSessionID == second.id)
        #expect(library.recentClosedItems.isEmpty)
    }

    @Test func defaultWindowNameCountsUp() {
        let library = WindowLibrary(directory: directory)
        #expect(library.defaultWindowName == "window 2")
        library.newWindow()
        #expect(library.defaultWindowName == "window 3")
    }

    @Test func windowInfoDistinguishesAutoFromCustomNames() {
        // auto-assigned "window N" → not custom (omitted from the title bar)
        #expect(WindowInfo(name: "window 1").hasCustomName == false)
        #expect(WindowInfo(name: "window 12").hasCustomName == false)
        #expect(WindowInfo.isAutoName("window 1"))
        // user-set names → custom
        #expect(WindowInfo(name: "work").hasCustomName)
        #expect(WindowInfo(name: "window").hasCustomName)        // no number
        #expect(WindowInfo(name: "window 0").hasCustomName)      // number must be >= 1
        #expect(WindowInfo(name: "Window 1").hasCustomName)      // case-sensitive vs the auto scheme
        #expect(WindowInfo(name: "my window 2").hasCustomName)   // extra words
    }

    // MARK: - Add / list / rename / delete

    @Test func newWindowAppendsOpensAndSeeds() {
        let library = WindowLibrary(directory: directory)
        let info = library.newWindow(name: "work")
        #expect(library.windows.map(\.name).contains("work"))
        #expect(library.isOpen(info.id))
        let store = try! #require(library.store(for: info.id))
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].sessions.count == 1)
    }

    @Test func newWindowBecomesFrontmostAndActive() {
        let library = WindowLibrary(directory: directory)
        let first = library.windows[0].id
        let info = library.newWindow(name: "work")
        // a new window is the active one immediately — the palette / quick terminal key off this, so
        // they target the new window without waiting on its first didBecomeKey.
        #expect(info.id != first)
        #expect(library.frontmostWindowID == info.id)
        #expect(library.activeWindowID == info.id)
    }

    @Test func controlWindowNodesProjectListMetadata() {
        let library = WindowLibrary(directory: directory)
        let first = library.windows[0]
        let second = library.newWindow(name: "work")

        // the second window has auto-follow enabled (30s) and its sidebar hidden; the first leaves
        // auto-follow off (nil autoFollowMs) with the sidebar visible (the default).
        library.store(for: second.id)?.autoFollowTimeout = 30
        library.store(for: second.id)?.setSidebarVisible(false)

        #expect(library.controlWindowNodes() == [
            ControlWindowNode(id: first.id.uuidString, name: first.name, open: true, active: false,
                              sidebarVisible: true),
            ControlWindowNode(id: second.id.uuidString, name: "work", open: true, active: true,
                              autoFollowMs: 30_000, sidebarVisible: false),
        ])
    }

    @Test func controlWindowNodesIncludeGeometryFromClosure() {
        let library = WindowLibrary(directory: directory)
        let first = library.windows[0]
        let second = library.newWindow(name: "work")
        // the app-side closure supplies each window's live frame; here a fake maps only the second window.
        let frame = ControlWindowFrame(x: 10, y: 20, width: 800, height: 600, display: 0)
        let nodes = library.controlWindowNodes(geometry: { $0 == second.id ? frame : nil })
        #expect(nodes[0].id == first.id.uuidString)
        #expect(nodes[0].geometry == nil)   // no frame supplied for the first window
        #expect(nodes[1].geometry == frame) // the closure's frame rides the second node
        // the default (no closure) omits geometry entirely — the host-free / non-AppKit path.
        #expect(library.controlWindowNodes().allSatisfy { $0.geometry == nil })
    }

    @Test func controlWindowNodesIncludeFullscreenZoomFromClosure() {
        let library = WindowLibrary(directory: directory)
        let first = library.windows[0]
        let second = library.newWindow(name: "work")
        // the app-side flags closure supplies each window's live fullscreen/zoom state.
        let nodes = library.controlWindowNodes(flags: { $0 == second.id ? (fullscreen: true, zoomed: false) : nil })
        #expect(nodes[0].id == first.id.uuidString)
        #expect(nodes[0].fullscreen == nil) // no flags supplied for the first window
        #expect(nodes[0].zoomed == nil)
        #expect(nodes[1].fullscreen == true) // the closure's flags ride the second node
        #expect(nodes[1].zoomed == false)
        // the default (no closure) omits both — the host-free / non-AppKit path.
        #expect(library.controlWindowNodes().allSatisfy { $0.fullscreen == nil && $0.zoomed == nil })
    }

    @Test func controlWindowNodesUseActiveWindowFallback() {
        let library = WindowLibrary(directory: directory)
        let first = library.windows[0]
        let second = library.newWindow(name: "work")

        library.closeWindow(second.id)
        library.frontmostWindowID = second.id

        // the open window reports its live sidebar visibility; the closed one has no store, so nil (omitted).
        #expect(library.controlWindowNodes() == [
            ControlWindowNode(id: first.id.uuidString, name: first.name, open: true, active: true,
                              sidebarVisible: true),
            ControlWindowNode(id: second.id.uuidString, name: "work", open: false, active: false),
        ])
    }

    @Test func resolveWindowActiveUsesActiveWindowFallback() {
        let library = WindowLibrary(directory: directory)
        let first = library.windows[0].id
        let second = library.newWindow(name: "work").id
        library.frontmostWindowID = second

        #expect(library.resolveWindow("active") == .resolved(second))

        library.closeWindow(second)
        #expect(library.resolveWindow("active") == .resolved(first))
    }

    @Test func resolveWindowMatchesExactAndUniquePrefix() throws {
        let first = UUID(uuidString: "0A11AAAA-0000-0000-0000-000000000011")!
        let second = UUID(uuidString: "7B33CCCC-0000-0000-0000-000000000013")!
        try writeWindowFile(first, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "a", sessions: [])]))
        try writeWindowFile(second, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "b", sessions: [])]))
        try writeIndex(WindowsIndex(frontmost: second, windows: [
            WindowEntry(id: first, name: "a", isOpen: true),
            WindowEntry(id: second, name: "b", isOpen: true),
        ]))

        let library = WindowLibrary(directory: directory)

        #expect(library.resolveWindow(first.uuidString.lowercased()) == .resolved(first))
        #expect(library.resolveWindow("7b33") == .resolved(second))
    }

    @Test func resolveWindowReportsAmbiguousAndMissingTargets() throws {
        let first = UUID(uuidString: "0A11AAAA-0000-0000-0000-000000000011")!
        let second = UUID(uuidString: "0A22BBBB-0000-0000-0000-000000000012")!
        try writeWindowFile(first, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "a", sessions: [])]))
        try writeWindowFile(second, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "b", sessions: [])]))
        try writeIndex(WindowsIndex(windows: [
            WindowEntry(id: first, name: "a", isOpen: true),
            WindowEntry(id: second, name: "b", isOpen: true),
        ]))

        let library = WindowLibrary(directory: directory)

        #expect(library.resolveWindow("0a") == .ambiguous([first, second]))
        #expect(library.resolveWindow("deadbeef") == .notFound)
    }

    @Test func resolveWindowIncludesClosedWindowsAsCandidates() {
        let library = WindowLibrary(directory: directory)
        let closed = library.newWindow(name: "closed").id
        library.closeWindow(closed)

        #expect(library.resolveWindow(closed.uuidString) == .resolved(closed))
    }

    @Test func newWindowBlankNameFallsBackToDefault() {
        let library = WindowLibrary(directory: directory)
        let info = library.newWindow(name: "   ")
        #expect(info.name == "window 2")
    }

    @Test func renameWindowUpdatesNameAndIgnoresBlank() {
        let library = WindowLibrary(directory: directory)
        let id = library.windows[0].id
        library.renameWindow(id, to: "personal")
        #expect(library.windows[0].name == "personal")
        library.renameWindow(id, to: "  ")
        #expect(library.windows[0].name == "personal")
    }

    @Test func removeWindowDropsEntryStoreAndFile() throws {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        #expect(FileManager.default.fileExists(atPath: windowFileURL(extra.id).path))
        library.removeWindow(extra.id)
        #expect(!library.windows.contains { $0.id == extra.id })
        #expect(library.store(for: extra.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: windowFileURL(extra.id).path))
    }

    @Test func removeWindowKeepsAtLeastOne() {
        let library = WindowLibrary(directory: directory)
        #expect(!library.canRemoveWindow)
        let only = library.windows[0].id
        library.removeWindow(only)
        #expect(library.windows.count == 1)
        #expect(library.windows[0].id == only)
    }

    @Test func removeWindowClearsFrontmostWhenItMatches() {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        library.frontmostWindowID = extra.id
        library.removeWindow(extra.id)
        #expect(library.frontmostWindowID == nil)
    }

    @Test func removeWindowCancelsPendingSaveSoFileStaysDeleted() throws {
        // a debounced save scheduled just before delete must NOT re-create the per-window file after
        // removeWindow deletes it. removeWindow cancels the store's pending save first, so even holding
        // the store reference (keeping it alive past the drop, as the real-world willClose closure does)
        // leaves no scheduled write to resurrect windows/<id>.json. The async timer can't fire in
        // synchronous test code, so the assertion is the deterministic observable contract: the file is
        // gone and stays gone.
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        let store = try #require(library.store(for: extra.id)) // hold a strong ref past the store drop
        let session = try #require(store.workspaces.first?.sessions.first)
        store.selectSession(session.id) // debounced save scheduled — would re-create the file when it fires
        #expect(FileManager.default.fileExists(atPath: windowFileURL(extra.id).path))
        library.removeWindow(extra.id)
        #expect(library.store(for: extra.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: windowFileURL(extra.id).path))
        _ = store // keep the store alive through the assertions above (mirrors the willClose retention)
    }

    @Test func removeWindowSweepsRenderedTextPNGsOfAClosedWindow() throws {
        // deleting a CLOSED window (no live store) must still sweep its sessions' rendered `.text`
        // watermark PNGs — `removeWindow` reads the session ids from the persisted snapshot, not the
        // (absent) store. The state-dir root is the test `directory` (WindowLibrary + WatermarkStorage
        // resolve against the same root), so the PNGs land where the sweep looks, no env mutation.
        let closed = UUID(), kept = UUID()
        let doomedSession = UUID(), keptSession = UUID()
        try writeWindowFile(closed, Snapshot(workspaces: [WorkspaceSnapshot(
            id: UUID(), name: "ws", sessions: [SessionSnapshot(id: doomedSession, customName: nil, cwd: "/tmp")])]))
        try writeWindowFile(kept, Snapshot(workspaces: [WorkspaceSnapshot(
            id: UUID(), name: "ws", sessions: [SessionSnapshot(id: keptSession, customName: nil, cwd: "/tmp")])]))
        try writeIndex(WindowsIndex(frontmost: kept, windows: [
            WindowEntry(id: closed, name: "closed", isOpen: false),
            WindowEntry(id: kept, name: "kept", isOpen: true),
        ]))

        // stand in for WatermarkRenderer's PNGs (host-free test, no AppKit), keyed by session id.
        WatermarkStorage.ensureDirectory(stateDir: directory)
        let doomedPNG = WatermarkStorage.renderedTextURL(sessionID: doomedSession, stateDir: directory)
        let keptPNG = WatermarkStorage.renderedTextURL(sessionID: keptSession, stateDir: directory)
        try Data("png".utf8).write(to: doomedPNG)
        try Data("png".utf8).write(to: keptPNG)

        let library = WindowLibrary(directory: directory)
        #expect(!library.isOpen(closed)) // precondition: the target window is closed (no store to sweep from)
        library.removeWindow(closed)

        #expect(!FileManager.default.fileExists(atPath: doomedPNG.path)) // deleted window's PNG swept
        #expect(FileManager.default.fileExists(atPath: keptPNG.path))    // surviving window's PNG untouched
    }

    @Test func removeWindowSweepsRenderedTextPNGsOfAnOpenWindow() throws {
        // the OPEN-window path reads session ids from the live store; it must sweep into the same
        // state-dir root (the test `directory`) so a deleted open window's PNGs go too.
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        let store = try #require(library.store(for: extra.id))
        let session = try #require(store.workspaces.first?.sessions.first)

        WatermarkStorage.ensureDirectory(stateDir: directory)
        let png = WatermarkStorage.renderedTextURL(sessionID: session.id, stateDir: directory)
        try Data("png".utf8).write(to: png)

        library.removeWindow(extra.id)
        #expect(!FileManager.default.fileExists(atPath: png.path))
    }

    // MARK: - Open-set / frontmost / close

    @Test func closeWindowMarksClosedButKeepsEntry() {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        #expect(library.isOpen(extra.id))
        library.closeWindow(extra.id)
        #expect(!library.isOpen(extra.id))
        #expect(library.windows.contains { $0.id == extra.id })
        #expect(library.openIDs() == [library.windows[0].id])
    }

    @Test func closeUnknownWindowIsNoOp() {
        let library = WindowLibrary(directory: directory)
        let before = library.openIDs()
        library.closeWindow(UUID())
        #expect(library.openIDs() == before)
    }

    @Test func closeWindowIsNoOpWhileTerminating() {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        library.isTerminating = true
        // during quit the open-set must survive for the next launch's reopen-all.
        library.closeWindow(extra.id)
        #expect(library.isOpen(extra.id))
    }

    @Test func loadStoreReopensAClosedWindow() {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        library.closeWindow(extra.id)
        let store = try! #require(library.loadStore(for: extra.id))
        #expect(library.isOpen(extra.id))
        #expect(store.workspaces.count == 1)
    }

    @Test func loadStoreUnknownIdReturnsNil() {
        let library = WindowLibrary(directory: directory)
        #expect(library.loadStore(for: UUID()) == nil)
    }

    @Test func frontmostTrackingPersistsThroughIndex() {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        library.frontmostWindowID = extra.id
        library.saveIndex()
        let reloaded = WindowLibrary(directory: directory)
        #expect(reloaded.frontmostWindowID == extra.id)
    }

    // MARK: - Cross-window session lookup

    @Test func storeForSessionFindsOwningOpenWindow() throws {
        let library = WindowLibrary(directory: directory)
        let a = library.windows[0]
        let b = library.newWindow(name: "b")
        let storeA = try #require(library.store(for: a.id))
        let storeB = try #require(library.store(for: b.id))
        let sessionA = try #require(storeA.workspaces.first?.sessions.first)
        let sessionB = try #require(storeB.workspaces.first?.sessions.first)
        #expect(library.store(forSession: sessionA.id) === storeA)
        #expect(library.store(forSession: sessionB.id) === storeB)
        #expect(library.windowID(forSession: sessionA.id) == a.id)
        #expect(library.windowID(forSession: sessionB.id) == b.id)
    }

    @Test func sessionLookupMissForUnknownAndClosedWindows() throws {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        let store = try #require(library.store(for: extra.id))
        let session = try #require(store.workspaces.first?.sessions.first)
        // a session in an open window is found.
        #expect(library.store(forSession: session.id) === store)
        // an unknown id misses.
        #expect(library.store(forSession: UUID()) == nil)
        #expect(library.windowID(forSession: UUID()) == nil)
        // once the window closes, its sessions are no longer searchable.
        library.closeWindow(extra.id)
        #expect(library.store(forSession: session.id) == nil)
        #expect(library.windowID(forSession: session.id) == nil)
    }

    // MARK: - Launch reopen latch + claim queue

    @Test func consumeReopenReturnsExtraCountOnceAndSeedsClaimQueue() throws {
        let library = WindowLibrary(directory: directory)
        let a = library.windows[0].id
        let b = library.newWindow(name: "b").id
        library.frontmostWindowID = a
        // two open windows → SwiftUI auto-opens one, so one extra openWindow() call is needed.
        #expect(library.consumeReopen() == 1)
        #expect(library.hasReopened)
        // a second call (another window's .task) is a no-op.
        #expect(library.consumeReopen() == 0)
        // the claim queue is launch window (frontmost a) first, then b.
        #expect(library.claimNextWindowID() == a)
        #expect(library.claimNextWindowID() == b)
        // drained → nil (an extra restored window dismisses itself).
        #expect(library.claimNextWindowID() == nil)
    }

    @Test func consumeReopenSingleWindowNeedsNoExtra() throws {
        let library = WindowLibrary(directory: directory)
        let only = library.windows[0].id
        #expect(library.consumeReopen() == 0)
        #expect(library.claimNextWindowID() == only)
        #expect(library.claimNextWindowID() == nil)
    }

    // the launch window's `.onAppear` may fire before the scene `.task` seeds the queue: it adopts the
    // launch id via the fallback. `consumeReopen` must then exclude that adopted id from the seeded
    // queue, so the single reopened window claims b (not a again) — no two windows binding one store.
    @Test func consumeReopenExcludesFallbackAdoptedLaunchID() throws {
        let library = WindowLibrary(directory: directory)
        let a = library.windows[0].id
        let b = library.newWindow(name: "b").id
        library.frontmostWindowID = a
        // launch window's .onAppear runs first: queue empty + not reopened → adopt the launch id (a).
        #expect(library.adoptLaunchWindowID() == a)
        // now the scene .task runs: still one extra openWindow() needed (N-1 = 1), but the queue must
        // NOT re-offer a — only b remains for the reopened window.
        #expect(library.consumeReopen() == 1)
        #expect(library.claimNextWindowID() == b)
        #expect(library.claimNextWindowID() == nil)
    }

    // single window, fallback ordering: the lone launch window adopts its id via the fallback, so
    // consumeReopen needs no extra window AND leaves an empty queue (the launch window already has it).
    @Test func consumeReopenSingleWindowFallbackAdoptedNeedsNoExtra() throws {
        let library = WindowLibrary(directory: directory)
        let only = library.windows[0].id
        #expect(library.adoptLaunchWindowID() == only)
        #expect(library.consumeReopen() == 0)
        #expect(library.claimNextWindowID() == nil)
    }

    // the persisted frontmost may point at a CLOSED window (quit with a closed window frontmost, two
    // others open). `launchWindowID` must fall through to an OPEN id, so `consumeReopen` seeds the
    // whole open set and returns open.count - 1 — every open window gets claimed, none binds the
    // closed store. Pre-fix `launchWindowID` returned the closed frontmost unconditionally, seeding a
    // 3-entry queue but returning 1, so the last open window never reopened (off-by-two).
    @Test func consumeReopenSeedsAllOpenWhenFrontmostIsClosed() throws {
        let x = UUID()
        let y = UUID()
        let z = UUID()
        try writeWindowFile(x, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "x", sessions: [])]))
        try writeWindowFile(y, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "y", sessions: [])]))
        try writeWindowFile(z, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "z", sessions: [])]))
        // frontmost z is CLOSED; x and y are open.
        try writeIndex(WindowsIndex(frontmost: z, windows: [
            WindowEntry(id: x, name: "x", isOpen: true),
            WindowEntry(id: y, name: "y", isOpen: true),
            WindowEntry(id: z, name: "z", isOpen: false),
        ]))
        let library = WindowLibrary(directory: directory)
        #expect(Set(library.openIDs()) == Set([x, y]))
        #expect(library.frontmostWindowID == z)
        // two open windows → SwiftUI auto-opens one, one extra openWindow() for the other.
        #expect(library.consumeReopen() == 1)
        // the launch window claims an OPEN id (not the closed frontmost z), the reopened window the other.
        let launchID = try #require(library.claimNextWindowID())
        let reopenedID = try #require(library.claimNextWindowID())
        #expect(launchID != z)
        #expect(reopenedID != z)
        #expect(Set([launchID, reopenedID]) == Set([x, y]))
        // queue exactly covers the open set — no stray, no undercount.
        #expect(library.claimNextWindowID() == nil)
    }

    @Test func enqueueClaimAppendsToQueue() throws {
        let library = WindowLibrary(directory: directory)
        let only = library.windows[0].id
        _ = library.consumeReopen()
        #expect(library.claimNextWindowID() == only)
        // a freshly opened window enqueues its id for the next appearing SwiftUI window.
        let extra = library.newWindow(name: "extra").id
        library.closeWindow(extra)
        library.enqueueClaim(extra)
        #expect(library.claimNextWindowID() == extra)
        #expect(library.claimNextWindowID() == nil)
    }

    // a repeated window.select / reveal of the same window before its first claim is consumed must not
    // enqueue the id twice — else two SwiftUI windows would claim it and one bundle would open in two
    // on-screen windows. Pure queue-membership dedup (the "already on-screen, raise" check lives at the
    // call site, not in enqueueClaim).
    @Test func enqueueClaimDedupesPendingClaims() throws {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra").id
        library.closeWindow(extra)
        _ = library.consumeReopen()
        _ = library.claimNextWindowID() // drain the launch id so the queue starts empty.
        // three rapid opens of the same closed window before any claim is consumed enqueue it once.
        library.enqueueClaim(extra)
        library.enqueueClaim(extra)
        library.enqueueClaim(extra)
        #expect(library.claimNextWindowID() == extra)
        #expect(library.claimNextWindowID() == nil)
        // once the first claim is consumed, a fresh enqueue of the same id is queued again.
        library.enqueueClaim(extra)
        #expect(library.claimNextWindowID() == extra)
        #expect(library.claimNextWindowID() == nil)
    }

    // newWindow pre-loads the new window's store BEFORE the caller enqueues its id (the
    // AppActions.newWindow / window.new path). enqueueClaim must NOT skip a store-loaded id — else the
    // claim is dropped, the spawned SwiftUI window claims nil and self-dismisses, and "New Window"
    // creates a library record but renders no on-screen window. The fresh id is queued and claimable.
    @Test func enqueueClaimQueuesNewWindowWithLoadedStore() throws {
        let library = WindowLibrary(directory: directory)
        _ = library.consumeReopen()
        _ = library.claimNextWindowID() // drain the launch id so the queue starts empty.
        let info = library.newWindow(name: "fresh") // pre-loads stores[info.id].
        #expect(library.isOpen(info.id)) // store is loaded, as the app does before enqueueing.
        library.enqueueClaim(info.id)
        #expect(library.claimNextWindowID() == info.id)
        #expect(library.claimNextWindowID() == nil)
    }

    // two adoptLaunchWindowID() calls before consumeReopen (SwiftUI restored more than one window,
    // each hitting the empty-queue fallback) must NOT both get the same launch id — only the first
    // does; the second gets nil and dismisses itself, so two windows can't bind the one launch store.
    @Test func adoptLaunchWindowIDIsIdempotentPerLaunch() throws {
        let library = WindowLibrary(directory: directory)
        let only = library.windows[0].id
        #expect(library.adoptLaunchWindowID() == only)
        // a second caller before consumeReopen gets nil (not the same id again).
        #expect(library.adoptLaunchWindowID() == nil)
    }

    // MARK: - Active store resolution

    @Test func activeStoreFollowsFrontmost() throws {
        let library = WindowLibrary(directory: directory)
        let a = library.windows[0]
        let b = library.newWindow(name: "b")
        let storeA = try #require(library.store(for: a.id))
        let storeB = try #require(library.store(for: b.id))
        library.frontmostWindowID = a.id
        #expect(library.activeStore === storeA)
        library.frontmostWindowID = b.id
        #expect(library.activeStore === storeB)
    }

    @Test func activeStoreFallsBackToFirstOpenWhenNoFrontmost() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.store(for: library.windows[0].id))
        library.newWindow(name: "extra")
        library.frontmostWindowID = nil
        // with no frontmost set, the first open window's store is used.
        #expect(library.activeStore === first)
    }

    @Test func activeStoreSkipsClosedFrontmost() throws {
        let library = WindowLibrary(directory: directory)
        let a = library.windows[0]
        let b = library.newWindow(name: "b")
        let storeA = try #require(library.store(for: a.id))
        // frontmost points at b, then b closes → fall back to the first open store (a).
        library.frontmostWindowID = b.id
        library.closeWindow(b.id)
        #expect(library.activeStore === storeA)
    }

    @Test func activeWindowIDFollowsFrontmostThenFallsBack() throws {
        let library = WindowLibrary(directory: directory)
        let a = library.windows[0]
        let b = library.newWindow(name: "b")
        library.frontmostWindowID = b.id
        #expect(library.activeWindowID == b.id)
        // closing the frontmost falls back to the first open window.
        library.closeWindow(b.id)
        #expect(library.activeWindowID == a.id)
        // an unset frontmost also falls back to the first open window.
        library.frontmostWindowID = nil
        #expect(library.activeWindowID == a.id)
    }

    // MARK: - Persistence round-trip

    @Test func indexRoundTripsThroughDisk() throws {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "personal")
        library.frontmostWindowID = extra.id
        library.saveIndex()

        let reloaded = WindowLibrary(directory: directory)
        #expect(reloaded.windows.map(\.name) == ["window 1", "personal"])
        #expect(reloaded.windows.map(\.id) == [library.windows[0].id, extra.id])
        #expect(reloaded.frontmostWindowID == extra.id)
        // both were open at save → both reopen.
        #expect(Set(reloaded.openIDs()) == Set([library.windows[0].id, extra.id]))
    }

    @Test func perWindowTreePersistsAndReloads() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows[0].id))
        let ws = try #require(store.workspaces.first)
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/var/log"))
        store.renameSession(session.id, to: "logs")

        let reloaded = WindowLibrary(directory: directory)
        let reloadedStore = try #require(reloaded.store(for: reloaded.windows[0].id))
        #expect(reloadedStore.workspaces[0].sessions.count == 2)
        #expect(reloadedStore.workspaces[0].sessions[1].displayName == "logs")
    }

    @Test func closedWindowDoesNotReopenButStaysListed() throws {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        library.closeWindow(extra.id)

        let reloaded = WindowLibrary(directory: directory)
        #expect(reloaded.windows.map(\.id).contains(extra.id))
        #expect(!reloaded.isOpen(extra.id))
        #expect(reloaded.openIDs() == [library.windows[0].id])
    }

    @Test func reopenFallsBackToFrontmostWhenNoneOpen() throws {
        // an index with both windows closed must still open one (never windowless).
        let a = UUID()
        let b = UUID()
        try writeWindowFile(a, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "ws", sessions: [])]))
        try writeWindowFile(b, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "ws", sessions: [])]))
        try writeIndex(WindowsIndex(frontmost: b, windows: [
            WindowEntry(id: a, name: "a", isOpen: false),
            WindowEntry(id: b, name: "b", isOpen: false),
        ]))
        let library = WindowLibrary(directory: directory)
        #expect(library.openIDs() == [b])
    }

    @Test func reopenFallsBackToFirstWhenNoFrontmost() throws {
        let a = UUID()
        try writeWindowFile(a, Snapshot(workspaces: []))
        try writeIndex(WindowsIndex(frontmost: nil, windows: [WindowEntry(id: a, name: "a", isOpen: false)]))
        let library = WindowLibrary(directory: directory)
        #expect(library.openIDs() == [a])
    }

    // a STALE frontmost (pointing at a window no longer in the list — e.g. removed out of band) with
    // every window closed must NOT leave the app windowless: `loadStore(stale)` no-ops (the id isn't in
    // `windows`), so the fallback must drop the stale id and open the first window instead.
    @Test func reopenWithStaleFrontmostStillOpensAWindow() throws {
        let a = UUID()
        let stale = UUID()
        try writeWindowFile(a, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "ws", sessions: [])]))
        try writeIndex(WindowsIndex(frontmost: stale, windows: [WindowEntry(id: a, name: "a", isOpen: false)]))
        let library = WindowLibrary(directory: directory)
        // never windowless: the stale frontmost is ignored, the first (only) window opens.
        #expect(library.openIDs() == [a])
    }

    // MARK: - Migration

    @Test func migratesLegacyWorkspacesIntoOneWindow() throws {
        let wsID = UUID()
        let sessionID = UUID()
        let snapshot = Snapshot(selectedSessionID: sessionID, workspaces: [
            WorkspaceSnapshot(id: wsID, name: "legacy", sessions: [
                SessionSnapshot(id: sessionID, customName: "build", cwd: "/legacy"),
            ]),
        ])
        try PersistenceStore(directory: directory).save(snapshot)

        let library = WindowLibrary(directory: directory)
        #expect(library.windows.count == 1)
        #expect(library.windows[0].name == "window 1")
        #expect(library.frontmostWindowID == library.windows[0].id)
        let store = try #require(library.store(for: library.windows[0].id))
        #expect(store.workspaces.map(\.name) == ["legacy"])
        #expect(store.workspaces[0].sessions[0].displayName == "build")
        // migration wrote a per-window file and the index.
        #expect(FileManager.default.fileExists(atPath: windowFileURL(library.windows[0].id).path))
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        // the legacy file is left in place.
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test func emptyLegacyFileSeedsInsteadOfMigrating() throws {
        try PersistenceStore(directory: directory).save(Snapshot())
        let library = WindowLibrary(directory: directory)
        // empty legacy tree → seed a fresh default window, not an empty migrated one.
        #expect(library.windows.count == 1)
        let store = try #require(library.store(for: library.windows[0].id))
        #expect(store.workspaces[0].name == "workspace 1")
        #expect(store.workspaces[0].sessions.count == 1)
    }

    @Test func existingIndexIgnoresLegacy() throws {
        // legacy present AND a valid index → the index wins, legacy ignored.
        try PersistenceStore(directory: directory).save(Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "legacy", sessions: []),
        ]))
        let indexedID = UUID()
        try writeWindowFile(indexedID, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "indexed", sessions: [])]))
        try writeIndex(WindowsIndex(frontmost: indexedID, windows: [WindowEntry(id: indexedID, name: "indexed-win", isOpen: true)]))

        let library = WindowLibrary(directory: directory)
        #expect(library.windows.map(\.name) == ["indexed-win"])
        let store = try #require(library.store(for: indexedID))
        #expect(store.workspaces.map(\.name) == ["indexed"])
    }

    // MARK: - Recovery matrix

    @Test func corruptIndexFallsBackToSeed() throws {
        try Data("{ not valid json ]".utf8).write(to: indexURL)
        let library = WindowLibrary(directory: directory)
        // no legacy → seed one default window.
        #expect(library.windows.count == 1)
        #expect(library.windows[0].name == "window 1")
        let store = try #require(library.store(for: library.windows[0].id))
        #expect(store.workspaces[0].sessions.count == 1)
    }

    @Test func corruptIndexWithLegacyMigrates() throws {
        try Data("garbage".utf8).write(to: indexURL)
        try PersistenceStore(directory: directory).save(Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "legacy", sessions: []),
        ]))
        let library = WindowLibrary(directory: directory)
        // corrupt index treated as absent → migrate from legacy.
        let store = try #require(library.store(for: library.windows[0].id))
        #expect(store.workspaces.map(\.name) == ["legacy"])
    }

    @Test func versionMismatchIndexTreatedAsAbsent() throws {
        var future = WindowsIndex(windows: [WindowEntry(id: UUID(), name: "future", isOpen: true)])
        future.version = WindowsIndex.currentVersion + 1
        try writeIndex(future)
        let library = WindowLibrary(directory: directory)
        // mismatched version → seeded default, not the future entry.
        #expect(library.windows.map(\.name) == ["window 1"])
    }

    @Test func emptyWindowsArrayIndexTreatedAsAbsent() throws {
        try writeIndex(WindowsIndex(frontmost: nil, windows: []))
        let library = WindowLibrary(directory: directory)
        #expect(library.windows.map(\.name) == ["window 1"])
    }

    @Test func missingPerWindowFileLoadsEmptyTree() throws {
        let id = UUID()
        // index references a window whose per-window file was never written.
        try writeIndex(WindowsIndex(frontmost: id, windows: [WindowEntry(id: id, name: "orphan", isOpen: true)]))
        let library = WindowLibrary(directory: directory)
        #expect(library.windows.map(\.name) == ["orphan"])
        let store = try #require(library.store(for: id))
        // a missing per-window file opens an empty tree (no crash, no abort).
        #expect(store.workspaces.isEmpty)
        #expect(library.isOpen(id))
    }

    @Test func corruptPerWindowFileLoadsEmptyTree() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try Data("{ corrupt ]".utf8).write(to: windowFileURL(id))
        try writeIndex(WindowsIndex(frontmost: id, windows: [WindowEntry(id: id, name: "corrupt", isOpen: true)]))
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: id))
        #expect(store.workspaces.isEmpty)
    }

    // MARK: - Orphan recovery (index lost, per-window files survive)

    // a corrupt index plus surviving per-window files must recover the windows (sessions intact),
    // not discard them by falling through to legacy/seeding.
    @Test func corruptIndexRecoversOrphanedPerWindowFiles() throws {
        let aID = UUID()
        let bID = UUID()
        let aSession = UUID()
        let bSession = UUID()
        try writeWindowFile(aID, Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "alpha", sessions: [
                SessionSnapshot(id: aSession, customName: "a-sess", cwd: "/a"),
            ]),
        ]))
        try writeWindowFile(bID, Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "beta", sessions: [
                SessionSnapshot(id: bSession, customName: "b-sess", cwd: "/b"),
            ]),
        ]))
        try Data("{ not valid json ]".utf8).write(to: indexURL)

        let library = WindowLibrary(directory: directory)
        // both windows recovered and open, with auto-assigned default names.
        #expect(library.windows.count == 2)
        #expect(Set(library.windows.map(\.id)) == Set([aID, bID]))
        #expect(Set(library.openIDs()) == Set([aID, bID]))
        #expect(library.windows.allSatisfy { WindowInfo.isAutoName($0.name) })
        // sessions from the per-window snapshots survived intact.
        let storeA = try #require(library.store(for: aID))
        let storeB = try #require(library.store(for: bID))
        #expect(storeA.workspaces.map(\.name) == ["alpha"])
        #expect(storeA.workspaces[0].sessions[0].displayName == "a-sess")
        #expect(storeB.workspaces.map(\.name) == ["beta"])
        #expect(storeB.workspaces[0].sessions[0].displayName == "b-sess")
        // a frontmost was picked from the recovered set, and the healed index round-trips.
        let frontmost = try #require(library.frontmostWindowID)
        #expect([aID, bID].contains(frontmost))
        let reloaded = WindowLibrary(directory: directory)
        #expect(Set(reloaded.windows.map(\.id)) == Set([aID, bID]))
    }

    // a version-mismatched index is treated as absent too — the surviving per-window files recover.
    @Test func versionMismatchIndexRecoversOrphanedPerWindowFiles() throws {
        let id = UUID()
        let sessionID = UUID()
        try writeWindowFile(id, Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "kept", sessions: [
                SessionSnapshot(id: sessionID, customName: "survivor", cwd: "/kept"),
            ]),
        ]))
        var future = WindowsIndex(windows: [WindowEntry(id: UUID(), name: "future", isOpen: true)])
        future.version = WindowsIndex.currentVersion + 1
        try writeIndex(future)

        let library = WindowLibrary(directory: directory)
        // the mismatched index is ignored; the orphan file recovers (not the "future" entry, not a seed).
        #expect(library.windows.map(\.id) == [id])
        #expect(library.windows[0].name == "window 1")
        let store = try #require(library.store(for: id))
        #expect(store.workspaces.map(\.name) == ["kept"])
        #expect(store.workspaces[0].sessions[0].displayName == "survivor")
    }

    // a non-UUID file in the windows/ dir is skipped; with no recoverable UUID files present and a
    // legacy file, bootstrap still falls through to legacy migration (one "window 1").
    @Test func noOrphanFilesFallsThroughToLegacyMigration() throws {
        try Data("garbage".utf8).write(to: indexURL)
        // a stray non-UUID file in the windows dir must NOT be mistaken for a recoverable window.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("windows"),
                                                withIntermediateDirectories: true)
        try Data("noise".utf8).write(to: directory.appendingPathComponent("windows").appendingPathComponent("notes.json"))
        try PersistenceStore(directory: directory).save(Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "legacy", sessions: []),
        ]))

        let library = WindowLibrary(directory: directory)
        // no recoverable per-window files → legacy migration, one default-named window.
        #expect(library.windows.count == 1)
        #expect(library.windows[0].name == "window 1")
        let store = try #require(library.store(for: library.windows[0].id))
        #expect(store.workspaces.map(\.name) == ["legacy"])
    }

    // nothing present (no index, no orphan files, no legacy) → seed exactly one default window.
    @Test func nothingPresentSeedsExactlyOneWindow() throws {
        let library = WindowLibrary(directory: directory)
        #expect(library.windows.count == 1)
        #expect(library.windows[0].name == "window 1")
        let store = try #require(library.store(for: library.windows[0].id))
        #expect(store.workspaces.count == 1)
        #expect(store.workspaces[0].sessions.count == 1)
    }

    // MARK: - Reset per-session font sizes across all windows

    // a global font/appearance change resets every surface to the new default, so per-session font
    // overrides must be cleared in CLOSED windows too — else a closed window reopens later overriding
    // the new default. The open window clears live; the closed one's snapshot file is rewritten.
    @Test func resetSessionFontSizesAllWindowsClearsClosedAndOpen() throws {
        // a closed window whose persisted session carries a font-size override.
        let closedID = UUID()
        let closedSession = UUID()
        try writeWindowFile(closedID, Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "ws", sessions: [
                SessionSnapshot(id: closedSession, customName: nil, cwd: "/tmp", fontSize: 18),
            ]),
        ]))
        // an open window whose live session also carries an override.
        let openID = UUID()
        try writeWindowFile(openID, Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "ws", sessions: [])]))
        try writeIndex(WindowsIndex(frontmost: openID, windows: [
            WindowEntry(id: openID, name: "open", isOpen: true),
            WindowEntry(id: closedID, name: "closed", isOpen: false),
        ]))
        let library = WindowLibrary(directory: directory)
        let openStore = try #require(library.store(for: openID))
        let openWs = try #require(openStore.workspaces.first)
        let openSession = try #require(openStore.addSession(toWorkspace: openWs.id, cwd: "/tmp"))
        openStore.setFontSize(openSession.id, 22)
        #expect(library.isOpen(openID))
        #expect(!library.isOpen(closedID))

        library.resetSessionFontSizesAllWindows()

        // open window: live override cleared.
        #expect(openStore.session(withID: openSession.id)?.fontSize == nil)
        // closed window: its snapshot file rewritten with the override stripped.
        let reloaded = PersistenceStore(directory: directory.appendingPathComponent("windows"),
                                        fileName: "\(closedID.uuidString).json").load()
        #expect(reloaded.workspaces.first?.sessions.first?.fontSize == nil)
        // the closed window stayed closed (no store was loaded to clear it).
        #expect(!library.isOpen(closedID))
    }

    // MARK: - openCounts

    @Test func openCountsSumsOpenWindowsAndSessions() throws {
        let library = WindowLibrary(directory: directory)
        // the seeded window already has one workspace + one session; add a second session to it.
        let firstStore = try #require(library.store(for: library.windows[0].id))
        let firstWs = try #require(firstStore.workspaces.first)
        _ = try #require(firstStore.addSession(toWorkspace: firstWs.id, cwd: "/tmp"))
        // a second open window seeds one more session.
        _ = library.newWindow(name: "work")
        let counts = library.openCounts()
        #expect(counts.windows == 2)
        #expect(counts.sessions == 3)
    }

    @Test func openCountsExcludesClosedWindows() throws {
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        #expect(library.openCounts().windows == 2)
        library.closeWindow(extra.id)
        let counts = library.openCounts()
        #expect(counts.windows == 1)
        #expect(counts.sessions == 1)
    }

    // MARK: - saveAllOpen

    @Test func saveAllOpenFlushesEveryOpenStore() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows[0].id))
        let ws = try #require(store.workspaces.first)
        let session = try #require(store.workspaces.first?.sessions.first)
        // simulate a live cwd change that AppStore doesn't auto-persist.
        session.currentCwd = "/changed"
        // add another open window too.
        library.newWindow(name: "extra")
        library.saveAllOpen()

        // the cwd change is now on disk for the first window.
        let reloaded = WindowLibrary(directory: directory)
        let reloadedStore = try #require(reloaded.store(for: reloaded.windows[0].id))
        let reloadedSession = try #require(reloadedStore.session(withID: session.id))
        #expect(reloadedSession.initialCwd == "/changed")
        _ = ws
    }
}
