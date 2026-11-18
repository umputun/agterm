import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryFollowCompanionsTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-follow-\(UUID().uuidString)")
    private let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func copy(of origin: UUID, in store: AppStore, host: String = "buildbox", endpoint: ControlZmxEndpoint? = nil) throws -> Session {
        let row = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp", remoteHost: host,
                                                remoteSessionID: origin.uuidString))
        store.bindRemote(RemoteBinding(remoteSessionID: origin.uuidString, daemonsByLocalPane: [row.paneIdentity: ZmxSupport.daemonName(for: UUID())],
                                       presentationVersion: 1,
                                       origin: .init(host: host, endpoint: endpoint ?? self.endpoint, sessionName: "parent")),
                         forSession: row.id)
        return row
    }

    @Test func aHandledCompanionReachesOpenPendingAndClosedWindowCopiesOfItsOriginOnly() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.store(for: library.activeWindowID))
        let origin = UUID()
        let child = UUID().uuidString
        let open = try copy(of: origin, in: store)
        let pending = try copy(of: origin, in: store)
        let otherSession = try copy(of: UUID(), in: store)
        let otherHost = try copy(of: origin, in: store, host: "elsewhere")
        let otherEndpoint = try copy(of: origin, in: store, endpoint: ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/other"))
        #expect(store.softCloseSession(pending.id))
        let closed = library.newWindow()
        let saved = try copy(of: origin, in: try #require(library.store(for: closed.id)))
        library.closeWindow(closed.id)

        library.markOriginCompanionsHandled([child.lowercased()], parent: origin.uuidString.lowercased(), host: "buildbox", endpoint: endpoint)

        #expect(open.followedCompanions == [child])
        #expect(pending.followedCompanions == [child])
        for untouched in [otherSession, otherHost, otherEndpoint] { #expect(untouched.followedCompanions.isEmpty) }
        let reopened = try #require(library.loadStore(for: closed.id))
        #expect(reopened.session(withID: saved.id)?.followedCompanions == [child])
    }

    @Test func aParkedOnlyCopyKeepsItsSavedRowThroughGraceAndTakesTheMarkOnUndo() throws {
        let library = WindowLibrary(directory: directory)
        let id = try #require(library.activeWindowID)
        let store = try #require(library.store(for: id))
        let origin = UUID()
        let child = UUID().uuidString
        let parked = try copy(of: origin, in: store)
        store.save()
        let saved = { try library.persistenceStore(for: id).loadChecked().workspaces.flatMap { $0.attached ?? [] } }
        #expect(try saved().map(\.session.id) == [parked.id])
        #expect(store.softCloseSession(parked.id))

        library.markOriginCompanionsHandled([child], parent: origin.uuidString, host: "buildbox", endpoint: endpoint)

        #expect(parked.followedCompanions == [child])
        #expect(try saved().map(\.session.id) == [parked.id])
        #expect(store.undoPendingClose())
        #expect(try saved().first?.followedCompanions == [child])
    }
}
