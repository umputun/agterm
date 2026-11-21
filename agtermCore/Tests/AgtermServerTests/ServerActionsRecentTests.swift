import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsRecentTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness(history: true) }

    private func newSession(cwd: String? = nil) throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: cwd, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    private var entries: [ControlRecentItem] { harness.actions.listRecentClosed().result?.recent ?? [] }

    private func daemon(_ identity: UUID) -> String { ZmxSupport.daemonName(for: identity) }

    private var state: String { harness.scratch.state }

    private func journal(failing: Bool = false) throws {
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        if failing {
            let path = state + "/" + PendingCloseJournal.fileName
            try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        harness.actions.pendingCloses = PendingCloseJournal(directory: URL(fileURLWithPath: state))
    }

    private func journaled() throws -> [UUID] {
        try PendingCloseJournal(directory: URL(fileURLWithPath: state)).load().map(\.session)
    }

    private func failCatalogSaves() throws {
        let catalog = state + "/workspaces.json"
        try? FileManager.default.removeItem(atPath: catalog)
        try FileManager.default.createDirectory(atPath: catalog, withIntermediateDirectories: true)
    }

    @Test func anUndoInsideTheGraceBringsTheSessionBackWithItsDaemon() throws {
        let session = try newSession()

        let close = harness.actions.closeSession(session.id.uuidString, window: nil, undoable: true)
        let undoID = try #require(close.result?.undoID)
        #expect(close.result?.undoable == true)
        #expect(close.result?.recentID != nil)
        #expect(harness.store.session(withID: session.id) == nil)
        #expect(entries.map(\.sessionIDs) == [[session.id.uuidString]])

        let undo = harness.actions.undoClose(undoID)

        #expect(undo == ControlResponse(ok: true, result: ControlResult(id: undoID)))
        #expect(harness.store.session(withID: session.id) === session)
        #expect(harness.runner.kills.isEmpty)
        #expect(entries.isEmpty)
    }

    @Test func aCloseTheJournalCannotRecordIsFinalAndLeavesOtherPendingClosesAlone() throws {
        try journal()
        let earlier = try newSession()
        let earlierUndo = try #require(harness.actions.closeSession(earlier.id.uuidString, window: nil, undoable: true).result?.undoID)
        let session = try newSession()
        try journal(failing: true)

        let close = harness.actions.closeSession(session.id.uuidString, window: nil, undoable: true)

        #expect(close.ok)
        #expect(close.result?.undoable == false)
        #expect(close.result?.undoID == nil)
        #expect(close.result?.recentID != nil)
        #expect(harness.runner.kills == [daemon(session.paneIdentity)])
        #expect(entries.map(\.sessionIDs).contains([session.id.uuidString]))
        #expect(harness.store.pendingCloseID(ofSession: earlier.id)?.uuidString == earlierUndo)
    }

    @Test func anUndoWhoseCatalogDoesNotSaveIsAnErrorAndKeepsTheJournalAndEntry() async throws {
        try journal()
        let session = try newSession()
        let close = await harness.actions.serve(ControlRequest(cmd: .sessionClose, target: session.id.uuidString,
                                                               args: ControlArgs(undoable: true)))
        let undoID = try #require(close.result?.undoID)
        #expect(try journaled() == [session.id])
        try failCatalogSaves()

        let undo = await harness.actions.serve(ControlRequest(cmd: .sessionUndo, target: undoID))

        #expect(!undo.ok)
        #expect(try journaled() == [session.id])
        #expect(entries.map(\.sessionIDs) == [[session.id.uuidString]])
    }

    @Test func aReopenOfAPendingCloseWhoseCatalogDoesNotSaveIsAnErrorAndKeepsTheJournalAndEntry() async throws {
        try journal()
        let session = try newSession()
        let close = await harness.actions.serve(ControlRequest(cmd: .sessionClose, target: session.id.uuidString,
                                                               args: ControlArgs(undoable: true)))
        let recentID = try #require(close.result?.recentID)
        try failCatalogSaves()

        let reopen = await harness.actions.serve(ControlRequest(cmd: .recentOpen, target: recentID))

        #expect(!reopen.ok)
        #expect(try journaled() == [session.id])
        #expect(entries.map(\.id) == [recentID])
    }

    @Test func aRecoveryThatCannotClearTheJournalThrowsAndKeepsIt() throws {
        let session = try newSession()
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let path = state + "/" + PendingCloseJournal.fileName
        let entry = PendingCloseJournal.Entry(session: session.id, panes: [session.paneIdentity])
        try JSONEncoder().encode([entry]).write(to: URL(fileURLWithPath: path))
        let store = AppStore(persistence: PersistenceStore(directory: URL(fileURLWithPath: state)), snapshotDidSave: {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }, paneFinalizer: nil, headless: true)

        #expect(throws: PendingCloseJournal.Failure.self) {
            try PendingCloseJournal(directory: URL(fileURLWithPath: state)).recover(into: store, panes: harness.panes)
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func anUndoAfterTheGraceIsRefusedAndStartsNothing() throws {
        let session = try newSession()
        let undoID = try #require(harness.actions.closeSession(session.id.uuidString, window: nil, undoable: true).result?.undoID)
        harness.store.finalizeAllPendingCloses()
        let launches = harness.runner.launches.count

        let undo = harness.actions.undoClose(undoID)

        #expect(undo == ControlResponse(ok: false, error: AppStore.closeNoLongerUndoable))
        #expect(harness.runner.kills == [daemon(session.paneIdentity)])
        #expect(harness.runner.launches.count == launches)
        #expect(harness.store.session(withID: session.id) == nil)
        #expect(entries.count == 1)
    }

    @Test func aBatchCloseIsOneUndo() throws {
        let first = try newSession()
        let second = try newSession()

        let close = harness.actions.closeSessions([first.id.uuidString, second.id.uuidString], window: nil, undoable: true)
        let undoID = try #require(close.result?.undoID)
        #expect(close.result?.affected == 2)

        #expect(harness.actions.undoClose(undoID).ok)
        #expect(harness.store.session(withID: first.id) === first)
        #expect(harness.store.session(withID: second.id) === second)
        #expect(harness.runner.kills.isEmpty)
    }

    @Test func aReopenAfterTheGraceStartsAFreshShellInTheSavedDirectory() throws {
        let session = try newSession(cwd: harness.scratch.root)
        let recentID = try #require(harness.actions.closeSession(session.id.uuidString, window: nil).result?.recentID)
        #expect(harness.runner.kills == [daemon(session.paneIdentity)])

        let reply = harness.actions.openRecentClosed(recentID, window: nil)

        let open = try #require(reply.result?.recentOpen)
        #expect(open.complete)
        #expect(open.window == harness.catalog.id.uuidString)
        let restored = try #require(harness.store.session(withID: session.id))
        #expect(restored.daemonBackedPanes == [restored.paneIdentity])
        let launch = try #require(harness.runner.launches.last)
        #expect(launch.name == daemon(restored.paneIdentity))
        #expect(launch.argv.isEmpty)
        #expect(launch.directory == harness.scratch.root)
        #expect(entries.isEmpty)
    }

    @Test func anEndedRowReopensLiveWithItsPanesInTheCatalog() throws {
        let session = try newSession()
        harness.store.markSessionEnded(session.id)
        let recentID = try #require(harness.actions.closeSession(session.id.uuidString, window: nil).result?.recentID)

        #expect(harness.actions.openRecentClosed(recentID, window: nil).ok)

        let restored = try #require(harness.store.session(withID: session.id))
        #expect(!restored.ended)
        let row = try #require(harness.actions.streams.catalogHub.snapshot().workspaces.flatMap(\.sessions).first { $0.fields.id == session.id })
        #expect(row.fields.lifecycle == .live)
        #expect(row.panes.map(\.identity) == [restored.paneIdentity])
    }

    @Test func aCompanionWhoseParentIsClosedReopensUnderItsRecordedParent() async throws {
        let parent = try newSession()
        let companion = try harness.session(await harness.actions.createCompanion(parent.id.uuidString, options: CompanionOptions(),
                                                                                 window: nil))
        let companionEntry = try #require(harness.actions.closeSession(companion.id.uuidString, window: nil).result?.recentID)
        #expect(harness.actions.closeSession(parent.id.uuidString, window: nil).ok)

        let reply = harness.actions.openRecentClosed(companionEntry, window: nil)

        #expect(reply.ok)
        let restored = try #require(harness.store.session(withID: companion.id))
        #expect(restored.parentID == parent.id)
        #expect(harness.store.session(withID: parent.id)?.daemonBackedPanes.isEmpty == false)
        #expect(restored.daemonBackedPanes.isEmpty == false)
        #expect(entries.isEmpty)
    }

    @Test func aPaneThatCannotStartKeepsTheEntryAndLeavesNoRow() throws {
        let session = try newSession()
        let recentID = try #require(harness.actions.closeSession(session.id.uuidString, window: nil).result?.recentID)
        harness.runner.failure = "no zmx"

        let reply = harness.actions.openRecentClosed(recentID, window: nil)

        #expect(!reply.ok)
        #expect(reply.error?.contains("no zmx") == true)
        #expect(harness.store.session(withID: session.id) == nil)
        #expect(entries.map(\.id) == [recentID])
    }

    @Test func aCompanionWithNoRecordedParentIsRefused() async throws {
        let parent = try newSession()
        let companion = try harness.session(await harness.actions.createCompanion(parent.id.uuidString, options: CompanionOptions(),
                                                                                 window: nil))
        let companionEntry = try #require(harness.actions.closeSession(companion.id.uuidString, window: nil).result?.recentID)
        harness.store.discardSession(parent.id)

        let reply = harness.actions.openRecentClosed(companionEntry, window: nil)

        #expect(reply == ControlResponse(ok: false, error: "parent session is not open or in Recent Closed"))
        #expect(entries.map(\.id) == [companionEntry])
    }

    @Test func listAndClearAnswerForTheCatalogWindowOnly() throws {
        _ = harness.actions.closeSession(try newSession().id.uuidString, window: nil)
        _ = harness.actions.closeSession(try newSession().id.uuidString, window: nil)

        #expect(harness.actions.listRecentClosed(window: harness.catalog.id.uuidString).result?.recent?.count == 2)
        #expect(harness.actions.listRecentClosed(window: UUID().uuidString).ok == false)
        #expect(harness.actions.clearRecentClosed(window: harness.catalog.id.uuidString) == ControlResponse(ok: true))
        #expect(entries.isEmpty)
    }

    @Test func aFailedCreationWritesNoEntry() throws {
        harness.runner.failure = "no zmx"

        #expect(!harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)).ok)

        #expect(entries.isEmpty)
    }

    @Test func aPendingCloseStillClaimsItsDaemons() throws {
        let session = try newSession()
        _ = harness.actions.closeSession(session.id.uuidString, window: nil, undoable: true)

        let claim = try #require(harness.actions.paneClaims().first { $0.paneIdentity == session.paneIdentity })

        #expect(claim.pendingClose)
        #expect(claim.sessionID == session.id)
    }

    @Test func theCatalogCarriesTheListAndAnotherActorsCloseAndClear() async throws {
        let hub = harness.actions.streams.catalogHub
        #expect(hub.snapshot().recent == [])
        let session = try newSession()

        _ = await harness.actions.serve(ControlRequest(cmd: .sessionClose, target: session.id.uuidString))
        #expect(hub.snapshot().recent?.map(\.sessionIDs) == [[session.id.uuidString]])

        _ = await harness.actions.serve(ControlRequest(cmd: .recentClear))
        #expect(hub.snapshot().recent == [])
    }
}
