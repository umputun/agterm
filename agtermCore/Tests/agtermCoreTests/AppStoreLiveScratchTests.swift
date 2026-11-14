import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreLiveScratchTests {
    private final class FinalizeLog {
        var identities: [UUID] = []
    }

    private let log = FinalizeLog()
    private let store: AppStore
    private let session: Session

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let log = log
        store = AppStore(persistence: PersistenceStore(directory: dir), paneFinalizer: { log.identities += $0 })
        let workspace = store.addWorkspace(name: "work")
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/a"))
    }

    private func liveScratch(surfaceToken: String? = nil) -> UUID {
        let identity = UUID()
        store.recordLiveScratch(session.id, identity: identity)
        if let surfaceToken {
            session.scratchActive = true
            session.scratchSurface = SpySurface(paneToken: surfaceToken, backedByZmx: true)
        }
        return identity
    }

    @Test func closingALiveScratchEndsAndForgetsItsDaemon() {
        let identity = liveScratch()
        session.scratchActive = true
        session.scratchSurface = SpySurface(paneToken: identity.uuidString, backedByZmx: true)

        #expect(store.closeScratch(session.id))

        #expect(log.identities == [identity])
        #expect(session.scratchDaemon == nil)
        #expect(session.scratchSurface == nil)
        #expect(store.snapshot().workspaces.flatMap(\.sessions).first?.scratchPaneIdentity == nil)
    }

    @Test func closingARestoredScratchWithNoSurfaceLeavesItsDaemon() {
        let identity = liveScratch()

        #expect(!store.closeScratch(session.id))

        #expect(log.identities.isEmpty)
        #expect(session.scratchDaemon?.identity == identity)
    }

    @Test func replacingARestoredScratchWithNoSurfaceEndsItsDaemon() {
        let identity = liveScratch()

        #expect(store.replaceScratch(session.id))

        #expect(log.identities == [identity])
        #expect(session.scratchDaemon == nil)
        #expect(!session.scratchActive)
    }

    @Test func replacingAFallbackScratchEndsTheKeptDaemon() {
        let identity = liveScratch(surfaceToken: UUID().uuidString)

        #expect(store.replaceScratch(session.id))

        #expect(log.identities == [identity])
        #expect(session.scratchDaemon == nil)
        #expect(session.scratchSurface == nil)
    }

    @Test func replacingALiveScratchEndsItsDaemonOnce() {
        let identity = liveScratch()
        session.scratchActive = true
        session.scratchSurface = SpySurface(paneToken: identity.uuidString, backedByZmx: true)

        #expect(store.replaceScratch(session.id))

        #expect(log.identities == [identity])
    }

    @Test func replacingWithNoScratchAtAllIsANoOp() {
        #expect(!store.replaceScratch(session.id))
        #expect(log.identities.isEmpty)
    }

    @Test func aFallbackScratchShellLeavesTheKeptDaemonAlone() {
        let identity = liveScratch(surfaceToken: UUID().uuidString)

        #expect(store.closeScratch(session.id))

        #expect(log.identities.isEmpty)
        #expect(session.scratchDaemon?.identity == identity)
        #expect(session.scratchSurface == nil)
    }

    @Test func aRemoteRowsScratchIsNeverEndedHere() throws {
        let remote = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))
        remote.scratchDaemon = Session.ScratchDaemon(identity: UUID(), shown: true)

        #expect(!store.closeScratch(remote.id))

        #expect(log.identities.isEmpty)
        #expect(remote.scratchDaemon != nil)
    }

    @Test func aServerScratchIsNotEndedByAClose() {
        let (server, row) = makeHeadlessSession(split: false)
        row.scratchDaemon = Session.ScratchDaemon(identity: UUID(), shown: true)

        #expect(!server.closeScratch(row.id))

        #expect(row.scratchDaemon != nil)
    }

    @Test func aRecordedScratchIsSavedAndOwned() {
        let identity = liveScratch()

        #expect(session.scratchDaemon == Session.ScratchDaemon(identity: identity, shown: false))
        #expect(session.locallyManagedPaneIdentities == [session.paneIdentity, identity])
        #expect(store.snapshot().workspaces.flatMap(\.sessions).first?.scratchPaneIdentity == identity)
    }

    @Test func aRemoteRowRecordsNoScratch() throws {
        let remote = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))

        store.recordLiveScratch(remote.id, identity: UUID())

        #expect(remote.scratchDaemon == nil)
    }

    @Test func forgettingASavedScratchDropsItWithoutEndingIt() {
        _ = liveScratch()

        store.forgetSavedScratch(session.id)

        #expect(session.scratchDaemon == nil)
        #expect(log.identities.isEmpty)
        #expect(store.snapshot().workspaces.flatMap(\.sessions).first?.scratchPaneIdentity == nil)
    }

    @Test func closingTheSessionEndsItsScratchDaemonOnce() {
        let identity = liveScratch()

        store.closeSession(session.id)

        #expect(log.identities.filter { $0 == identity }.count == 1)
        #expect(log.identities.contains(session.paneIdentity))
    }

    @Test func theLayoutNamesTheLiveScratchFromItsRecordToItsEnd() {
        #expect(store.presentationLayout(of: session)?.scratch == nil)
        let identity = liveScratch()
        #expect(store.presentationLayout(of: session)?.scratch == identity)

        store.replaceScratch(session.id)

        #expect(store.presentationLayout(of: session)?.scratch == nil)
    }

    @Test func aServerStoreSavesNoScratch() {
        let (server, row) = makeHeadlessSession(split: false)
        row.scratchDaemon = Session.ScratchDaemon(identity: UUID(), shown: true)

        #expect(server.snapshot().workspaces.flatMap(\.sessions).first { $0.id == row.id }?.scratchPaneIdentity == nil)
    }
}
