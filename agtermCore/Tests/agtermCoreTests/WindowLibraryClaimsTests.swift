import Foundation
import Testing
@testable import agtermCore

/// Class suite so `init`/`deinit` bracket each test with its own temp state directory, matching
/// `WindowLibraryTests`. Covers only the zmx claim walk, which must never write.
@MainActor
final class WindowLibraryClaimsTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-claims-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var indexURL: URL { directory.appendingPathComponent("windows.json") }
    private var windowsDirectory: URL { directory.appendingPathComponent("windows") }
    private func windowFileURL(_ id: UUID) -> URL {
        windowsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func writeIndex(_ entries: [WindowEntry]) throws {
        try JSONEncoder().encode(WindowsIndex(windows: entries)).write(to: indexURL)
    }

    private func writeWindowFile(_ id: UUID, _ snapshot: Snapshot) throws {
        try PersistenceStore(directory: windowsDirectory, fileName: "\(id.uuidString).json").save(snapshot)
    }

    private func snapshot(session: SessionSnapshot) -> Snapshot {
        Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "workspace 1", sessions: [session])])
    }

    private func session(pane: UUID?, split: UUID? = nil, hasSplit: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: UUID(), paneIdentity: pane, splitPaneIdentity: split, customName: "build",
                        cwd: "/tmp", isSplit: hasSplit, hasSplit: hasSplit)
    }

    /// Every file the walk may read, hashed, so a test can prove the walk wrote nothing at all.
    private func stateFingerprint() throws -> [String: Data] {
        var seen: [String: Data] = [:]
        if let data = try? Data(contentsOf: indexURL) { seen["windows.json"] = data }
        let files = (try? FileManager.default.contentsOfDirectory(at: windowsDirectory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for file in files { seen[file.lastPathComponent] = try Data(contentsOf: file) }
        return seen
    }

    /// `reopen` opens the frontmost (else the first) window when the index lists none as open, so a test
    /// about a CLOSED window needs another window to absorb that fallback.
    private func writeOpenDecoy() throws -> WindowEntry {
        let id = UUID()
        try writeWindowFile(id, snapshot(session: session(pane: UUID())))
        return WindowEntry(id: id, name: "decoy", isOpen: true)
    }

    @Test func closedWindowContributesItsPersistedPanes() throws {
        let windowID = UUID()
        let pane = UUID()
        let split = UUID()
        try writeIndex([try writeOpenDecoy(), WindowEntry(id: windowID, name: "work", isOpen: false)])
        try writeWindowFile(windowID, snapshot(session: session(pane: pane, split: split, hasSplit: true)))

        let library = WindowLibrary(directory: directory)
        let walk = library.paneClaims()

        #expect(walk.complete)
        let mine = walk.claims.filter { $0.windowID == windowID }
        #expect(Set(mine.map(\.paneIdentity)) == Set([pane, split]))
        let states: Set<ZmxOwnerWindowState> = Set(mine.map(\.windowState))
        #expect(states == [.closed])
        #expect(Set(mine.compactMap(\.windowName)) == ["work"])
        let roles: Set<ZmxPaneRole> = Set(mine.map(\.pane))
        #expect(roles == [.left, .right])
    }

    @Test func openWindowContributesItsLiveSessionsNotItsFile() throws {
        let library = WindowLibrary(directory: directory)
        let windowID = library.windows[0].id
        let store = try #require(library.store(for: windowID))
        let live = try #require(store.workspaces.first?.sessions.first)

        let walk = library.paneClaims()
        #expect(walk.complete)
        #expect(walk.claims.map(\.paneIdentity) == [live.paneIdentity])
        #expect(walk.claims.first?.windowState == .open)
        #expect(walk.claims.first?.sessionID == live.id)
    }

    @Test func windowFileMissingFromTheIndexIsClaimedAsUnindexed() throws {
        let indexed = UUID()
        let stray = UUID()
        let strayPane = UUID()
        try writeIndex([WindowEntry(id: indexed, name: "work", isOpen: true)])
        try writeWindowFile(indexed, snapshot(session: session(pane: UUID())))
        try writeWindowFile(stray, snapshot(session: session(pane: strayPane)))

        let library = WindowLibrary(directory: directory)
        let walk = library.paneClaims()

        let orphaned = try #require(walk.claims.first { $0.paneIdentity == strayPane })
        #expect(orphaned.windowState == .unindexed)
        #expect(orphaned.windowName == nil)
        #expect(orphaned.windowID == stray)
        // the file is real state, so its panes are claimed rather than left to read as orphan daemons
        #expect(walk.complete)
    }

    @Test func unreadableWindowFileMakesTheWalkIncomplete() throws {
        let windowID = UUID()
        try writeIndex([try writeOpenDecoy(), WindowEntry(id: windowID, name: "work", isOpen: false)])
        try Data("{ not json".utf8).write(to: windowFileURL(windowID))

        let library = WindowLibrary(directory: directory)
        #expect(!library.paneClaims().complete)
    }

    @Test func missingPaneIdentityMakesTheWalkIncompleteRatherThanMintingOne() throws {
        let windowID = UUID()
        try writeIndex([try writeOpenDecoy(), WindowEntry(id: windowID, name: "work", isOpen: false)])
        try writeWindowFile(windowID, snapshot(session: session(pane: nil)))

        let library = WindowLibrary(directory: directory)
        let walk = library.paneClaims()
        #expect(!walk.complete)
        #expect(walk.claims.allSatisfy { $0.windowID != windowID })
    }

    @Test func splitWithoutItsIdentityMakesTheWalkIncomplete() throws {
        let windowID = UUID()
        try writeIndex([try writeOpenDecoy(), WindowEntry(id: windowID, name: "work", isOpen: false)])
        try writeWindowFile(windowID, snapshot(session: session(pane: UUID(), split: nil, hasSplit: true)))

        let library = WindowLibrary(directory: directory)
        #expect(!library.paneClaims().complete)
    }

    @Test func unreadableWindowsDirectoryMakesTheWalkIncomplete() throws {
        let library = WindowLibrary(directory: directory)
        // an unenumerable directory hides unindexed panes entirely, and prune must not act on that silence
        try FileManager.default.removeItem(at: windowsDirectory)
        try Data("not a directory".utf8).write(to: windowsDirectory)
        #expect(!library.paneClaims().complete)
    }

    @Test func aValidSplitSurvivesItsSessionsMissingPrimaryIdentity() throws {
        let windowID = UUID()
        let split = UUID()
        try writeIndex([try writeOpenDecoy(), WindowEntry(id: windowID, name: "work", isOpen: false)])
        try writeWindowFile(windowID, snapshot(session: session(pane: nil, split: split, hasSplit: true)))

        let library = WindowLibrary(directory: directory)
        let walk = library.paneClaims()
        #expect(!walk.complete)
        #expect(walk.claims.contains { $0.paneIdentity == split && $0.pane == .right })
    }

    @Test func sessionsCarryAHumanNameEvenWithoutACustomOne() throws {
        let windowID = UUID()
        let pane = UUID()
        let unnamed = SessionSnapshot(id: UUID(), paneIdentity: pane, customName: nil, cwd: "/tmp/project")
        try writeIndex([try writeOpenDecoy(), WindowEntry(id: windowID, name: "work", isOpen: false)])
        try writeWindowFile(windowID, snapshot(session: unnamed))

        let library = WindowLibrary(directory: directory)
        let claim = try #require(library.paneClaims().claims.first { $0.paneIdentity == pane })
        #expect(claim.sessionName == "project")
    }

    @Test func liveSessionsUseTheirDisplayName() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows[0].id))
        let live = try #require(store.workspaces.first?.sessions.first)
        let claim = try #require(library.paneClaims().claims.first { $0.paneIdentity == live.paneIdentity })
        #expect(claim.sessionName == live.displayName)
    }

    @Test func aSoftClosedSessionStaysClaimedForItsGraceWindow() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows[0].id))
        let live = try #require(store.workspaces.first?.sessions.first)
        let before = try stateFingerprint()

        #expect(store.softCloseSession(live.id))
        let walk = library.paneClaims()
        let claim = try #require(walk.claims.first { $0.paneIdentity == live.paneIdentity })
        #expect(claim.pendingClose)
        #expect(claim.windowState == .open)
        #expect(walk.complete)
        #expect(try stateFingerprint() == before)

        store.finalizeAllPendingCloses()
        #expect(!library.paneClaims().claims.contains { $0.paneIdentity == live.paneIdentity })
    }

    @Test func undoingASoftCloseReturnsAnOrdinaryClaim() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.windows[0].id))
        let live = try #require(store.workspaces.first?.sessions.first)

        #expect(store.softCloseSession(live.id))
        #expect(store.undoPendingClose())
        let claim = try #require(library.paneClaims().claims.first { $0.paneIdentity == live.paneIdentity })
        #expect(!claim.pendingClose)
    }

    /// Records what the library asks to have killed, so a test can prove a pending claim is finalized
    /// exactly once rather than dropped with its store.
    private final class FinalizerSpy {
        var identities: [UUID] = []
    }

    private func libraryWithSpy() -> (WindowLibrary, FinalizerSpy) {
        let spy = FinalizerSpy()
        let library = WindowLibrary(directory: directory, paneFinalizer: { spy.identities.append(contentsOf: $0) })
        return (library, spy)
    }

    @Test func closingAWindowFinalizesItsPendingClosesRatherThanDroppingThem() throws {
        let (library, spy) = libraryWithSpy()
        let first = library.windows[0].id
        library.newWindow(name: "second")
        let store = try #require(library.store(for: first))
        let live = try #require(store.workspaces.first?.sessions.first)

        #expect(store.softCloseSession(live.id))
        library.closeWindow(first)

        #expect(spy.identities == [live.paneIdentity])
        #expect(store.pendingCloseMembers().isEmpty)
    }

    @Test func deletingAWindowFinalizesItsPendingClosesExactlyOnce() throws {
        let (library, spy) = libraryWithSpy()
        let first = library.windows[0].id
        library.newWindow(name: "second")
        let store = try #require(library.store(for: first))
        let live = try #require(store.workspaces.first?.sessions.first)

        #expect(store.softCloseSession(live.id))
        library.removeWindow(first)

        #expect(spy.identities == [live.paneIdentity])
    }

    @Test func theWalkLeavesEveryStateFileByteIdentical() throws {
        let closed = UUID()
        let stray = UUID()
        try writeIndex([try writeOpenDecoy(), WindowEntry(id: closed, name: "work", isOpen: false)])
        try writeWindowFile(closed, snapshot(session: session(pane: nil)))
        try writeWindowFile(stray, snapshot(session: session(pane: UUID())))

        let library = WindowLibrary(directory: directory)
        let before = try stateFingerprint()
        _ = library.paneClaims()
        // windows.json too: a future helper calling saveIndex() would pass a windows/*.json-only check
        #expect(try stateFingerprint() == before)
    }
}
