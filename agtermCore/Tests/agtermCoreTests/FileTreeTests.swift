import Foundation
import Testing
@testable import agtermCore

struct FileTreeOrderTests {
    @Test func directoriesSortBeforeFiles() {
        let entries = [
            FileEntry(name: "readme.md", isDirectory: false),
            FileEntry(name: "src", isDirectory: true),
            FileEntry(name: "Makefile", isDirectory: false),
            FileEntry(name: "assets", isDirectory: true),
        ]
        // directories first (alphabetized), then files (alphabetized)
        #expect(FileTreeOrder.sorted(entries).map(\.name) == ["assets", "src", "Makefile", "readme.md"])
    }

    @Test func nameCompareIsCaseInsensitive() {
        let entries = [
            FileEntry(name: "banana", isDirectory: false),
            FileEntry(name: "Apple", isDirectory: false),
            FileEntry(name: "cherry", isDirectory: false),
        ]
        #expect(FileTreeOrder.sorted(entries).map(\.name) == ["Apple", "banana", "cherry"])
    }

    @Test func hiddenEntriesDroppedUnlessShown() {
        let entries = [
            FileEntry(name: ".git", isDirectory: true),
            FileEntry(name: "src", isDirectory: true),
            FileEntry(name: ".env", isDirectory: false),
            FileEntry(name: "main.swift", isDirectory: false),
        ]
        #expect(FileTreeOrder.filtered(entries, showHidden: false).map(\.name) == ["src", "main.swift"])
        #expect(FileTreeOrder.filtered(entries, showHidden: true).count == 4)
    }

    @Test func isHiddenMatchesDotPrefix() {
        #expect(FileEntry(name: ".git", isDirectory: true).isHidden)
        #expect(FileEntry(name: ".env", isDirectory: false).isHidden)
        #expect(!FileEntry(name: "src", isDirectory: true).isHidden)
        #expect(!FileEntry(name: "a.b", isDirectory: false).isHidden)
    }

    @Test func sortStaysStableOnCaseOnlyTwins() {
        // case-only twins compare "not before" in both directions, so sorted(by:) has a valid strict weak
        // ordering and never traps.
        let entries = [FileEntry(name: "Foo", isDirectory: false), FileEntry(name: "foo", isDirectory: false)]
        #expect(FileTreeOrder.sorted(entries).count == 2)
    }
}

@MainActor
struct FileTreeStateTests {
    @Test func showSeedsRootFromEffectiveCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        #expect(session.fileTreeVisible == false)
        #expect(session.fileTreeRoot == nil)
        store.setFileTreeVisible(true, forSession: session.id)
        #expect(session.fileTreeVisible)
        #expect(session.fileTreeRoot == "/proj")
    }

    @Test func showUsesLiveCwdOverInitial() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        session.currentCwd = "/proj/src"   // a cd happened before the panel opened
        store.toggleFileTree(session.id)
        #expect(session.fileTreeRoot == "/proj/src")
    }

    @Test func reshowRerootsToCurrentCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        store.setFileTreeVisible(true, forSession: session.id)   // root seeded = /proj
        session.currentCwd = "/proj/deep"                        // shell wandered off
        store.setFileTreeVisible(false, forSession: session.id)  // hide alone doesn't move the root
        #expect(session.fileTreeRoot == "/proj")
        store.setFileTreeVisible(true, forSession: session.id)   // re-show re-roots at the live cwd
        #expect(session.fileTreeRoot == "/proj/deep")
    }

    @Test func rerootSnapsToCurrentCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        store.setFileTreeVisible(true, forSession: session.id)
        session.currentCwd = "/proj/src"
        store.rerootFileTree(session.id)
        #expect(session.fileTreeRoot == "/proj/src")
    }

    @Test func rerootToExplicitPathOverridesCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        store.setFileTreeVisible(true, forSession: session.id)
        let before = session.fileTreeRefreshToken
        // an explicit path wins over the cwd (the `reroot <path>` control form), and still bumps the token.
        store.rerootFileTree(session.id, to: "/some/other/dir")
        #expect(session.fileTreeRoot == "/some/other/dir")
        #expect(session.fileTreeRefreshToken == before &+ 1)
    }

    @Test func unknownIdIsANoOp() {
        let store = makeStore()
        // must not crash / must not create anything
        store.setFileTreeVisible(true, forSession: UUID())
        store.toggleFileTree(UUID())
        store.rerootFileTree(UUID())
        #expect(store.workspaces.isEmpty)
    }

    @Test func visibleSurvivesRestoreWithRootPinnedToRestoredCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        store.setFileTreeVisible(true, forSession: session.id)
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        let r = restored.workspaces[0].sessions[0]
        #expect(r.fileTreeVisible)             // visibility persisted
        // the root itself is NOT persisted, but a restored-visible panel re-pins it to the restored cwd so
        // it stays fixed instead of chasing the live cwd (the reviewer-caught regression).
        #expect(r.fileTreeRoot == "/proj")
    }

    @Test func hiddenIsTheDefaultAfterRestore() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/proj")!
        let restored = makeStore()
        restored.restore(from: store.snapshot())
        let r = restored.workspaces[0].sessions[0]
        #expect(r.fileTreeVisible == false)
        #expect(r.fileTreeRoot == nil)   // hidden -> not pinned; seeds on its first show
    }
}

struct FileTreeSnapshotCodableTests {
    @Test func fileTreeVisibleRoundTripsThroughJSON() throws {
        let snap = SessionSnapshot(id: UUID(), customName: nil, cwd: "/a", fileTreeVisible: true)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(decoded.fileTreeVisible == true)
        #expect(decoded == snap)
    }

    @Test func missingFileTreeVisibleDecodesAsNil() throws {
        // a snapshot written before this field existed must still decode (forward-compat), not throw and
        // wipe the saved tree.
        let json = #"{"id":"\#(UUID().uuidString)","cwd":"/a"}"#
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(decoded.fileTreeVisible == nil)
    }
}
