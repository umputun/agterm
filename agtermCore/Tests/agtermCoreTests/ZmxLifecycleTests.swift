import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ZmxLifecycleTests {
    @Test func listParserKeepsClientCountsAndUnreachableNames() throws {
        let output = """
        name=agterm-a\tpid=10\tclients=0\tcreated=1\tcwd=/tmp
        name=agterm-b\tpid=11\tclients=2\tcreated=1\tcmd=zsh
        name=agterm-busy\terr=Timeout\tstatus=unreachable

        """

        #expect(try ZmxListParser.parse(output) == [
            ZmxSessionRecord(name: "agterm-a", clients: 0, leaderPID: 10),
            ZmxSessionRecord(name: "agterm-b", clients: 2, leaderPID: 11),
            ZmxSessionRecord(name: "agterm-busy", clients: nil),
        ])
    }

    @Test func listParserRejectsPartialOutputInsteadOfReapingFromIt() {
        #expect((try? ZmxListParser.parse("")) == [])
        #expect(throws: ZmxListParser.ParseError.self) {
            try ZmxListParser.parse("pid=10\tclients=0\n")
        }
        #expect(throws: ZmxListParser.ParseError.self) {
            try ZmxListParser.parse("name=agterm-a\tclients=wat\n")
        }
        #expect(throws: ZmxListParser.ParseError.self) {
            try ZmxListParser.parse("name=agterm-a\tpid=wat\tclients=0\n")
        }
    }

    @Test func leaderMapUsesOnlyAppNamesWithReadablePositivePids() throws {
        let app = ZmxSupport.daemonName(for: UUID())
        let noPID = ZmxSupport.daemonName(for: UUID())
        let unreachable = ZmxSupport.daemonName(for: UUID())
        let records = try ZmxListParser.parse("""
        name=\(app)\tpid=10\tclients=0
        name=other\tpid=11\tclients=0
        name=\(noPID)\tclients=0
        name=\(unreachable)\terr=Timeout\tstatus=unreachable
        """)

        #expect(ZmxLeaderMap.leaders(in: records) == [app: 10])
    }

    @Test func foregroundRefreshGateInvalidatesAndReconcilesSlowly() {
        var gate = ZmxRefreshGate()
        let start = Date(timeIntervalSince1970: 100)

        let first = gate.shouldRefresh(now: start)
        let held = gate.shouldRefresh(now: start.addingTimeInterval(1))
        #expect(first)
        #expect(!held)
        gate.noteLifecycleChange()
        let invalidated = gate.shouldRefresh(now: start.addingTimeInterval(2))
        let heldAgain = gate.shouldRefresh(now: start.addingTimeInterval(3))
        let reconciled = gate.shouldRefresh(
            now: start.addingTimeInterval(2 + ZmxRefreshGate.reconcileInterval))
        #expect(invalidated)
        #expect(!heldAgain)
        #expect(reconciled)
    }

    @Test func foregroundRefreshNeedsAtLeastOneActuallyWrappedPane() {
        let ordinary = Session(initialCwd: "/ordinary")
        ordinary.surface = SpySurface(backedByZmx: false)
        let wrapped = Session(initialCwd: "/wrapped")
        wrapped.surface = SpySurface(backedByZmx: true)

        #expect(!ZmxForegroundRefreshPolicy.hasWrappedPane(in: [ordinary]))
        #expect(ZmxForegroundRefreshPolicy.hasWrappedPane(in: [ordinary, wrapped]))
        wrapped.surface = SpySurface(backedByZmx: false)
        wrapped.hasSplit = true
        wrapped.splitSurface = SpySurface(backedByZmx: true)
        #expect(ZmxForegroundRefreshPolicy.hasWrappedPane(in: [wrapped]))
    }

    @Test func reapPolicyUsesCompleteLiveInventoryAndZeroClientAppNamesOnly() {
        let known = ZmxSupport.daemonName(for: UUID())
        let orphan = ZmxSupport.daemonName(for: UUID())
        let sessions = [
            ZmxSessionRecord(name: known, clients: 0),
            ZmxSessionRecord(name: orphan, clients: 0),
            ZmxSessionRecord(name: ZmxSupport.daemonName(for: UUID()), clients: 1),
            ZmxSessionRecord(name: "other", clients: 0),
            ZmxSessionRecord(name: ZmxSupport.daemonName(for: UUID()), clients: nil),
        ]

        #expect(ZmxReapPolicy.namesToKill(sessions: sessions, requestedMode: .live,
                                          knownNames: [known]) == [orphan])
        #expect(ZmxReapPolicy.namesToKill(sessions: sessions, requestedMode: .live, knownNames: nil) == nil)
        #expect(ZmxReapPolicy.namesToKill(sessions: sessions, requestedMode: .none,
                                          knownNames: nil) == [known, orphan])
    }

    /// pins the reap against a user's own zmx session: `ZMX_DIR` is exported into every wrapped pane, so
    /// `zmx new agterm-notes` typed in one lands in the namespace the reaper sweeps
    @Test func reapRefusesEveryNameOutsideTheGeneratedDaemonShape() {
        let ours = ZmxSupport.daemonName(for: UUID())
        let sessions = [
            ZmxSessionRecord(name: ours, clients: 0),
            ZmxSessionRecord(name: "agterm-notes", clients: 0),
            ZmxSessionRecord(name: ZmxSupport.namePrefix, clients: 0),
            ZmxSessionRecord(name: ZmxSupport.namePrefix + String(repeating: "a", count: 31), clients: 0),
            ZmxSessionRecord(name: ZmxSupport.namePrefix + String(repeating: "a", count: 33), clients: 0),
            ZmxSessionRecord(name: ZmxSupport.namePrefix + String(repeating: "A", count: 32), clients: 0),
            ZmxSessionRecord(name: ours + "-2", clients: 0),
        ]

        #expect(ZmxReapPolicy.namesToKill(sessions: sessions, requestedMode: .live, knownNames: []) == [ours])
        #expect(ZmxReapPolicy.namesToKill(sessions: sessions, requestedMode: .rerun,
                                          knownNames: nil) == [ours])
        #expect(ZmxReapPolicy.namesToKill(sessions: sessions, requestedMode: .none, knownNames: nil) == [ours])
    }

    @Test func leaderMapKeepsOnlyGeneratedDaemonNames() {
        let ours = ZmxSupport.daemonName(for: UUID())
        let leaders = ZmxLeaderMap.leaders(in: [
            ZmxSessionRecord(name: ours, clients: 0, leaderPID: 41),
            ZmxSessionRecord(name: "agterm-notes", clients: 0, leaderPID: 42),
        ])

        #expect(leaders == [ours: 41])
    }

    @Test func remoteSessionCloseFinalizesNothingWhileALocalOneStillDoes() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        let workspace = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/local"))
        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/remote",
                                                   remoteHost: "buildbox"))
        remote.hasSplit = true
        remote.splitPaneIdentity = UUID()

        store.closeSession(remote.id)
        #expect(finalized.isEmpty, "its daemons live on buildbox; this finalizer only kills local ones")

        store.closeSession(local.id)
        #expect(finalized.flatMap { $0 } == [local.paneIdentity])
    }

    @Test func remoteSplitCloseFinalizesNothingWhileALocalSplitStillDoes() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        let workspace = store.addWorkspace(name: "work")
        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/remote",
                                                   remoteHost: "buildbox"))
        remote.hasSplit = true
        remote.splitPaneIdentity = UUID()
        let local = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/local"))
        let localSplit = UUID()
        local.hasSplit = true
        local.splitPaneIdentity = localSplit

        store.closeSplit(remote.id)
        #expect(finalized.isEmpty)

        store.closeSplit(local.id)
        #expect(finalized.flatMap { $0 } == [localSplit])
    }

    @Test func theInventoryProjectionSkipsARemoteSessionEntirely() throws {
        let store = AppStore(persistence: temporaryPersistence())
        let workspace = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/local"))
        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/remote",
                                                   remoteHost: "buildbox"))
        remote.hasSplit = true
        remote.splitPaneIdentity = UUID()

        #expect(remote.locallyManagedPaneIdentities.isEmpty)
        #expect(PaneIdentityInventory.identities(in: [local, remote]) == [local.paneIdentity])
    }

    @Test func immediateSessionAndWorkspaceCloseFinalizeEveryOwnedPane() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        let firstWorkspace = store.addWorkspace(name: "first")
        let first = try #require(store.addSession(toWorkspace: firstWorkspace.id, cwd: "/first"))
        let firstSplit = UUID()
        first.hasSplit = true
        first.splitPaneIdentity = firstSplit
        let secondWorkspace = store.addWorkspace(name: "second")
        let second = try #require(store.addSession(toWorkspace: secondWorkspace.id, cwd: "/second"))

        store.closeSession(first.id)
        #expect(finalized == [[first.paneIdentity, firstSplit]])

        store.removeWorkspace(secondWorkspace.id)
        #expect(finalized == [[first.paneIdentity, firstSplit], [second.paneIdentity]])
    }

    @Test func undoKeepsPanesAndGraceFinalizationKillsThem() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/repo"))
        let split = UUID()
        session.hasSplit = true
        session.splitPaneIdentity = split

        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(finalized.isEmpty)
        #expect(store.undoPendingClose())
        #expect(finalized.isEmpty)

        #expect(store.softCloseSession(session.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(finalized == [[session.paneIdentity, split]])
    }

    @Test func workspaceGraceFinalizesAllPanesOnlyAfterTheUndoWindow() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        _ = store.addWorkspace(name: "kept")
        let removed = store.addWorkspace(name: "removed")
        let session = try #require(store.addSession(toWorkspace: removed.id, cwd: "/repo"))

        #expect(store.softRemoveWorkspace(removed.id, grace: 60))
        #expect(finalized.isEmpty)
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(finalized == [[session.paneIdentity]])
    }

    @Test func splitCloseFinalizesOnlySplitWhilePromotionMovesSurvivorIdentity() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/repo"))
        let split = UUID()
        session.hasSplit = true
        session.isSplit = true
        session.splitPaneIdentity = split

        store.closeSplit(session.id)
        #expect(finalized == [[split]])
        #expect(session.paneIdentity != split)

        finalized.removeAll()
        let promoted = UUID()
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        session.hasSplit = true
        session.isSplit = true
        session.splitPaneIdentity = promoted
        store.closePrimaryPane(session.id)
        #expect(finalized.isEmpty)
        #expect(session.paneIdentity == promoted)
        #expect(session.splitPaneIdentity == nil)
    }

    @Test func windowDeleteFinalizesOpenAndClosedWindowsWhileCloseAloneKeepsPanes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var finalized: [[UUID]] = []
        let library = WindowLibrary(directory: directory, paneFinalizer: { finalized.append($0) })
        let openExtra = library.newWindow(name: "open")
        let openSession = try #require(library.store(for: openExtra.id)?.workspaces.first?.sessions.first)
        library.removeWindow(openExtra.id)
        #expect(finalized == [[openSession.paneIdentity]])

        let closedExtra = library.newWindow(name: "closed")
        let closedSession = try #require(library.store(for: closedExtra.id)?.workspaces.first?.sessions.first)
        let closedIdentities = [closedSession.paneIdentity]

        library.closeWindow(closedExtra.id)
        #expect(finalized == [[openSession.paneIdentity]])
        library.removeWindow(closedExtra.id)
        #expect(finalized == [[openSession.paneIdentity], closedIdentities])
    }

    @Test func launchInventoryUpgradesLegacyPaneIdentitiesBeforeStoreRestore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let windowID = UUID()
        try writeIndex(WindowsIndex(windows: [WindowEntry(id: windowID, name: "window 1", isOpen: true)]),
                       directory: directory)
        try writeWindow(Snapshot(workspaces: [WorkspaceSnapshot(
            id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/repo", isSplit: true),
            ])]), id: windowID, directory: directory)
        var inventories: [Set<UUID>?] = []

        let library = WindowLibrary(directory: directory, paneFinalizer: nil,
                                    launchInventorySink: { inventories.append($0) })
        let restored = try #require(library.store(for: windowID)?.workspaces.first?.sessions.first)
        let disk = try PersistenceStore(
            directory: directory.appendingPathComponent("windows"),
            fileName: "\(windowID.uuidString).json").loadChecked()
        let persisted = try #require(disk.workspaces.first?.sessions.first)

        #expect(inventories == [Set([restored.paneIdentity, try #require(restored.splitPaneIdentity)])])
        #expect(persisted.paneIdentity == restored.paneIdentity)
        #expect(persisted.splitPaneIdentity == restored.splitPaneIdentity)
    }

    @Test func corruptClosedWindowMakesLaunchInventoryIncomplete() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let open = UUID(), closed = UUID()
        try writeIndex(WindowsIndex(windows: [
            WindowEntry(id: open, name: "open", isOpen: true),
            WindowEntry(id: closed, name: "closed", isOpen: false),
        ]), directory: directory)
        try writeWindow(Snapshot(workspaces: [WorkspaceSnapshot(
            id: UUID(), name: "work", sessions: [SessionSnapshot(id: UUID(), customName: nil, cwd: "/repo")])]),
                        id: open, directory: directory)
        let closedURL = directory.appendingPathComponent("windows/\(closed.uuidString).json")
        try Data("{".utf8).write(to: closedURL)
        var inventories: [Set<UUID>?] = []

        _ = WindowLibrary(directory: directory, paneFinalizer: nil,
                          launchInventorySink: { inventories.append($0) })
        #expect(inventories.count == 1)
        #expect(inventories[0] == nil)
    }

    @Test func snapshotRestoreKeepsTheDaemonNameForMissingDaemonUpsert() throws {
        let store = AppStore(persistence: temporaryPersistence())
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/repo"))
        let expected = ZmxSupport.daemonName(for: session.paneIdentity)
        let snapshot = store.snapshot()
        let restored = AppStore(persistence: temporaryPersistence())

        restored.restore(from: snapshot, launchRestore: true)
        let restoredSession = try #require(restored.workspaces.first?.sessions.first)
        #expect(ZmxSupport.daemonName(for: restoredSession.paneIdentity) == expected)
    }

    @Test func launchInventoryClaimsWindowFilesMissingFromAStaleIndex() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexed = UUID(), stray = UUID()
        let indexedPane = UUID(), strayPane = UUID()
        try writeIndex(WindowsIndex(windows: [WindowEntry(id: indexed, name: "indexed", isOpen: true)]),
                       directory: directory)
        try writeWindow(paneSnapshot(indexedPane), id: indexed, directory: directory)
        try writeWindow(paneSnapshot(strayPane), id: stray, directory: directory)
        var inventories: [Set<UUID>?] = []

        let library = WindowLibrary(directory: directory, paneFinalizer: nil,
                                    launchInventorySink: { inventories.append($0) })

        #expect(inventories == [Set([indexedPane, strayPane])])
        #expect(library.windows.map(\.id) == [indexed])
        #expect(library.store(for: stray) == nil)
    }

    @Test func unreadableUnindexedWindowFileMakesLaunchInventoryIncomplete() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexed = UUID(), stray = UUID()
        try writeIndex(WindowsIndex(windows: [WindowEntry(id: indexed, name: "indexed", isOpen: true)]),
                       directory: directory)
        try writeWindow(paneSnapshot(UUID()), id: indexed, directory: directory)
        try writeWindow(paneSnapshot(UUID()), id: stray, directory: directory)
        try Data("{".utf8).write(to: directory.appendingPathComponent("windows/\(stray.uuidString).json"))
        var inventories: [Set<UUID>?] = []

        _ = WindowLibrary(directory: directory, paneFinalizer: nil,
                          launchInventorySink: { inventories.append($0) })

        #expect(inventories == [nil])
    }

    @Test func unsavableStrayIdentityUpgradeMakesLaunchInventoryIncomplete() throws {
        let directory = temporaryDirectory()
        let windowsDirectory = directory.appendingPathComponent("windows")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: windowsDirectory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let indexed = UUID(), stray = UUID()
        try writeIndex(WindowsIndex(windows: [WindowEntry(id: indexed, name: "indexed", isOpen: true)]),
                       directory: directory)
        try writeWindow(paneSnapshot(UUID()), id: indexed, directory: directory)
        try writeWindow(Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
            SessionSnapshot(id: UUID(), customName: nil, cwd: "/repo"),
        ])]), id: stray, directory: directory)
        // read-only directory: `save(_:)` writes atomically through a sibling temp file, so the minted
        // identity cannot persist and an unpersisted claim must not be trusted by the reap
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: windowsDirectory.path)
        var inventories: [Set<UUID>?] = []

        _ = WindowLibrary(directory: directory, paneFinalizer: nil,
                          launchInventorySink: { inventories.append($0) })

        #expect(inventories == [nil])
    }

    private func paneSnapshot(_ pane: UUID) -> Snapshot {
        Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "work", sessions: [
            SessionSnapshot(id: UUID(), paneIdentity: pane, customName: nil, cwd: "/repo"),
        ])])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-zmx-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryPersistence() -> PersistenceStore {
        PersistenceStore(directory: temporaryDirectory())
    }

    private func writeIndex(_ index: WindowsIndex, directory: URL) throws {
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("windows.json"))
    }

    private func writeWindow(_ snapshot: Snapshot, id: UUID, directory: URL) throws {
        try PersistenceStore(directory: directory.appendingPathComponent("windows"),
                             fileName: "\(id.uuidString).json").save(snapshot)
    }
}
