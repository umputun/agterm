import Foundation
import Testing
@testable import agtermCore

/// Class suite (reference type) so `init`/`deinit` create and tear down a unique
/// temp directory around each test — no shared on-disk state, no Application
/// Support pollution.
@MainActor
final class PersistenceTests {
    private let directory: URL
    private let store: PersistenceStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PersistenceStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("workspaces.json") }

    @Test func snapshotRoundTripsThroughDisk() throws {
        let original = Snapshot(selectedSessionID: UUID(), workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: UUID(), customName: "build", cwd: "/Users/user/dev/foo"),
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/tmp"),
            ]),
            WorkspaceSnapshot(id: UUID(), name: "personal", sessions: []),
        ])
        try store.save(original)
        let decoded = store.load()
        #expect(decoded == original)
    }

    @Test func appStoreSnapshotCapturesTreeAndCwds() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let session = try! #require(app.addSession(toWorkspace: work.id, cwd: "/start"))
        session.currentCwd = "/Users/user/dev/live"
        app.renameSession(session.id, to: "build")
        let other = try! #require(app.addSession(toWorkspace: work.id, cwd: "/tmp"))

        let snapshot = app.snapshot()
        #expect(snapshot.selectedSessionID == other.id)
        #expect(snapshot.workspaces.count == 1)
        let ws = try! #require(snapshot.workspaces.first)
        #expect(ws.id == work.id)
        #expect(ws.name == "work")
        #expect(ws.sessions.map(\.id) == [session.id, other.id])
        #expect(ws.sessions[0].customName == "build")
        #expect(ws.sessions[0].cwd == "/Users/user/dev/live")
        #expect(ws.sessions[1].cwd == "/tmp")
    }

    @Test func restoreRebuildsTreeNamesAndCwds() {
        let selected = UUID()
        let snapshot = Snapshot(selectedSessionID: selected, workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: selected, customName: "build", cwd: "/Users/user/dev/foo"),
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/var/log"),
            ]),
            WorkspaceSnapshot(id: UUID(), name: "personal", sessions: [
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/"),
            ]),
        ])

        let app = AppStore(persistence: store)
        app.restore(from: snapshot)

        #expect(app.selectedSessionID == selected)
        #expect(app.workspaces.map(\.id) == snapshot.workspaces.map(\.id))
        #expect(app.workspaces.map(\.name) == ["work", "personal"])

        let first = app.workspaces[0]
        #expect(first.sessions.map(\.id) == snapshot.workspaces[0].sessions.map(\.id))
        #expect(first.sessions[0].customName == "build")
        #expect(first.sessions[0].initialCwd == "/Users/user/dev/foo")
        #expect(first.sessions[0].displayName == "build")
        #expect(first.sessions[1].customName == nil)
        #expect(first.sessions[1].initialCwd == "/var/log")
        #expect(first.sessions[1].displayName == "log")
        #expect(app.workspaces[1].sessions[0].displayName == "/")
        // surfaces stay lazy/nil until first display
        #expect(first.sessions[0].surface == nil)
        // currentCwd is nil after restore — only a live PWD report sets it; the
        // persisted cwd becomes initialCwd.
        #expect(first.sessions[0].currentCwd == nil)
        #expect(first.sessions[1].currentCwd == nil)
    }

    @Test func restoreClearsDanglingSelection() {
        let snapshot = Snapshot(selectedSessionID: UUID(), workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/a"),
            ]),
        ])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // the persisted selection points at no existing session, so it's cleared.
        #expect(app.selectedSessionID == nil)
        #expect(app.activeSession == nil)
    }

    @Test func restoreDoesNotWriteToDisk() {
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let snapshot = Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/a"),
            ]),
        ])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // restore loads what was just read from disk; it must not re-persist.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func snapshotRestoreRoundTripPreservesTree() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let personal = app.addWorkspace(name: "personal")
        app.addSession(toWorkspace: work.id, cwd: "/a")
        let b = try! #require(app.addSession(toWorkspace: personal.id, cwd: "/b"))
        app.renameSession(b.id, to: "server")
        app.selectSession(b.id)

        let snapshot = app.snapshot()
        let restored = AppStore(persistence: store)
        restored.restore(from: snapshot)
        #expect(restored.snapshot() == snapshot)
    }

    @Test func legacyFileWithRemovedKeysLoadsAndKeepsWorkspaces() throws {
        // a workspaces.json written by an older build carries removed keys (statusBarHidden,
        // titleBarHidden). they must be ignored, not fail the load and wipe the tree.
        let id = UUID()
        let json = #"{ "version": 1, "statusBarHidden": true, "titleBarHidden": true, "workspaces": [ { "id": "\#(id.uuidString)", "name": "work", "sessions": [] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [id])
    }

    @Test func sessionSplitStatePersistsAndRestores() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let session = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        app.toggleSplit(session.id)
        #expect(store.load().workspaces[0].sessions[0].isSplit == true)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.workspaces[0].sessions[0].isSplit == true)
    }

    @Test func sessionFlaggedStatePersistsAndRestores() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let flag = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        let plain = try! #require(app.addSession(toWorkspace: work.id, cwd: "/b"))
        flag.flagged = true
        app.save()
        #expect(store.load().workspaces[0].sessions[0].flagged == true)
        #expect(store.load().workspaces[0].sessions[1].flagged == false)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.workspaces[0].sessions[0].flagged == true)
        #expect(restored.workspaces[0].sessions[1].flagged == false)
        _ = plain
    }

    @Test func legacySnapshotWithoutFlaggedDecodesUnflagged() throws {
        // a workspaces.json written before `flagged` existed has no key; it must decode (not throw and
        // wipe the tree) with the session unflagged.
        let ws = UUID()
        let sid = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(sid.uuidString)", "customName": null, "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.workspaces[0].sessions[0].flagged == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.workspaces[0].sessions[0].flagged == false)
    }

    @Test func sidebarModePersistsAndRestores() {
        let app = AppStore(persistence: store)
        _ = app.addWorkspace(name: "work")
        #expect(store.load().sidebarMode == .tree)
        app.setSidebarMode(.flagged)
        #expect(store.load().sidebarMode == .flagged)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.sidebarMode == .flagged)

        app.setSidebarMode(.tree)
        let restoredTree = AppStore(persistence: store)
        restoredTree.restore(from: store.load())
        #expect(restoredTree.sidebarMode == .tree)
    }

    @Test func sidebarVisibilityPersistsAndRestoresThroughHelper() {
        let app = AppStore(persistence: store)
        _ = app.addWorkspace(name: "work")
        #expect(store.load().sidebarVisible == true)
        app.setSidebarVisible(false)
        #expect(store.load().sidebarVisible == false)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.sidebarVisible == false)

        app.toggleSidebarVisible()
        let restoredShown = AppStore(persistence: store)
        restoredShown.restore(from: store.load())
        #expect(restoredShown.sidebarVisible == true)
    }

    @Test func legacySnapshotWithoutSidebarModeDecodesTree() throws {
        // a workspaces.json written before `sidebarMode` existed has no key; it must decode (not throw
        // and wipe the tree) and restore to `.tree`.
        let ws = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.sidebarMode == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.sidebarMode == .tree)
    }

    @Test func focusedWorkspacePersistsAndRestores() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        #expect(store.load().focusedWorkspaceID == nil) // default unfocused
        app.setFocusedWorkspace(work.id)
        #expect(store.load().focusedWorkspaceID == work.id)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.focusedWorkspaceID == work.id)

        app.setFocusedWorkspace(nil)
        let restoredCleared = AppStore(persistence: store)
        restoredCleared.restore(from: store.load())
        #expect(restoredCleared.focusedWorkspaceID == nil)
    }

    @Test func legacySnapshotWithoutFocusedWorkspaceDecodesUnfocused() throws {
        // a workspaces.json written before `focusedWorkspaceID` existed has no key; it must decode (not
        // throw and wipe the tree) and restore to unfocused.
        let ws = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.focusedWorkspaceID == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.focusedWorkspaceID == nil)
    }

    @Test func sessionRecencyPersistsAndRestores() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let a = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        let b = try! #require(app.addSession(toWorkspace: work.id, cwd: "/b"))
        let c = try! #require(app.addSession(toWorkspace: work.id, cwd: "/c"))
        app.selectSession(a.id)
        app.selectSession(b.id)
        app.save() // selection saves are debounced; flush so the write lands before reading back
        #expect(store.load().sessionRecency == [b.id, a.id, c.id])

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.sessionRecency.items == [b.id, a.id, c.id])
    }

    @Test func restoreDropsStaleRecencyIds() {
        let id = UUID()
        let stale = UUID()
        let snapshot = Snapshot(selectedSessionID: id, workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: id, customName: nil, cwd: "/a"),
            ]),
        ], sessionRecency: [stale, id])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // the stale id points at no restored session; it must never reach the switcher.
        #expect(app.sessionRecency.items == [id])
    }

    @Test func restoreFloatsSelectionToRecencyFront() {
        let a = UUID()
        let b = UUID()
        let snapshot = Snapshot(selectedSessionID: b, workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: a, customName: nil, cwd: "/a"),
                SessionSnapshot(id: b, customName: nil, cwd: "/b"),
            ]),
        ], sessionRecency: [a, b])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // a hand-edited/out-of-sync order still puts the restored selection first.
        #expect(app.sessionRecency.items == [b, a])
    }

    @Test func malformedRecencyDropsToNilKeepingTree() throws {
        // a present-but-invalid sessionRecency (hand-edit typo, wrong type) must drop to nil
        // lossily — never fail the whole Snapshot decode and wipe the tree on the next save.
        let ws = UUID()
        let session = UUID()
        let tree = #""selectedSessionID": "\#(session.uuidString)", "workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ]"#
        for bad in [#""sessionRecency": ["not-a-uuid"]"#, #""sessionRecency": 42"#] {
            try Data(#"{ "version": 1, \#(bad), \#(tree) }"#.utf8).write(to: fileURL)
            let loaded = store.load()
            #expect(loaded.workspaces.map(\.id) == [ws])
            #expect(loaded.selectedSessionID == session)
            #expect(loaded.sessionRecency == nil)
        }
    }

    @Test func restoreInsertsAbsentSelectionAtFront() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let snapshot = Snapshot(selectedSessionID: c, workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: a, customName: nil, cwd: "/a"),
                SessionSnapshot(id: b, customName: nil, cwd: "/b"),
                SessionSnapshot(id: c, customName: nil, cwd: "/c"),
            ]),
        ], sessionRecency: [a, b])
        let app = AppStore(persistence: store)
        app.restore(from: snapshot)
        // a selection missing from the persisted seed is inserted at the FRONT, not appended.
        #expect(app.sessionRecency.items == [c, a, b])
    }

    @Test func legacySnapshotWithoutRecencyDecodesSelectionOnly() throws {
        // a workspaces.json written before `sessionRecency` existed has no key; it must decode (not
        // throw and wipe the tree) and restore with just the selection in the Ctrl-Tab order.
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "selectedSessionID": "\#(session.uuidString)", "workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.sessionRecency == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.sessionRecency.items == [session])
    }

    @Test func sessionFontSizePersistsAndRestores() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let session = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        app.setFontSize(session.id, 17.5)
        app.save() // font saves are debounced; flush so the write lands before reading back
        #expect(store.load().workspaces[0].sessions[0].fontSize == 17.5)

        let restored = AppStore(persistence: store)
        restored.restore(from: store.load())
        #expect(restored.workspaces[0].sessions[0].fontSize == 17.5)
    }

    @Test func workspaceCollapsePersistsAndRestores() {
        let app = AppStore(persistence: store)
        let a = app.addWorkspace(name: "a")
        let b = app.addWorkspace(name: "b")
        app.setWorkspacesExpanded([a.id]) // collapse b, keep a expanded
        let disk = store.load()
        #expect(disk.workspaces[0].collapsed == nil)  // expanded → omitted
        #expect(disk.workspaces[1].collapsed == true) // collapsed → written

        let restored = AppStore(persistence: store)
        restored.restore(from: disk)
        #expect(restored.workspaces[0].isExpanded)     // a
        #expect(!restored.workspaces[1].isExpanded)    // b
        _ = b
    }

    @Test func legacyWorkspaceWithoutCollapsedDecodesExpanded() throws {
        // a workspaces.json written before `collapsed` existed has no key; it must decode (not throw and
        // wipe the tree) and restore expanded — lack of the field means expanded, for back-compat.
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "workspaces": "# +
            #"[ { "id": "\#(ws.uuidString)", "name": "work", "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces.map(\.id) == [ws])
        #expect(loaded.workspaces[0].collapsed == nil)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.workspaces[0].isExpanded)
    }

    @Test func explicitCollapsedFalseDecodesExpanded() throws {
        // an explicit `collapsed: false` (a hand-edit, or a snapshot from a future build that always writes
        // the field) must decode to expanded, same as an absent key — `!(false ?? false)` == expanded.
        let ws = UUID()
        let session = UUID()
        let json = #"{ "version": 1, "workspaces": [ { "id": "\#(ws.uuidString)", "name": "work", "# +
            #""collapsed": false, "sessions": [ { "id": "\#(session.uuidString)", "cwd": "/a" } ] } ] }"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded.workspaces[0].collapsed == false)

        let app = AppStore(persistence: store)
        app.restore(from: loaded)
        #expect(app.workspaces[0].isExpanded)
    }

    @Test func selectSessionPersistsSelectionToDisk() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let a = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        let b = try! #require(app.addSession(toWorkspace: work.id, cwd: "/b"))
        // selection saves are debounced; flush via save() so the write lands before reading back.
        app.selectSession(a.id)
        app.save()
        #expect(store.load().selectedSessionID == a.id)
        app.selectSession(b.id)
        app.save()
        #expect(store.load().selectedSessionID == b.id)
    }

    @Test func selectSessionNilDeselectsAndPersists() {
        let app = AppStore(persistence: store)
        let work = app.addWorkspace(name: "work")
        let a = try! #require(app.addSession(toWorkspace: work.id, cwd: "/a"))
        // selection saves are debounced; flush via save() so the write lands before reading back.
        app.selectSession(a.id)
        app.save()
        #expect(store.load().selectedSessionID == a.id)
        app.selectSession(nil)
        app.save()
        #expect(app.selectedSessionID == nil)
        #expect(store.load().selectedSessionID == nil)
    }

    @Test func loadMissingFileReturnsDefault() {
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let loaded = store.load()
        #expect(loaded == Snapshot())
        #expect(loaded.workspaces.isEmpty)
        #expect(loaded.selectedSessionID == nil)
    }

    @Test func loadCorruptFileReturnsDefault() throws {
        try Data("{ not valid json ]".utf8).write(to: fileURL)
        let loaded = store.load()
        #expect(loaded == Snapshot())
    }

    @Test func loadVersionMismatchReturnsDefault() throws {
        var future = Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [])])
        future.version = Snapshot.currentVersion + 1
        let data = try JSONEncoder().encode(future)
        try data.write(to: fileURL)
        let loaded = store.load()
        #expect(loaded == Snapshot())
        #expect(loaded.workspaces.isEmpty)
    }

    @Test func saveCreatesDirectoryWhenMissing() throws {
        let nested = directory.appendingPathComponent("does/not/exist/yet")
        let nestedStore = PersistenceStore(directory: nested)
        let snapshot = Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [])])
        try nestedStore.save(snapshot)
        #expect(nestedStore.load() == snapshot)
    }
}
