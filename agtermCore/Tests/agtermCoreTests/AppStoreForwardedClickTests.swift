import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreForwardedClickTests {
    let store = AppStore(persistence: PersistenceStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")))

    @Test func aForwardedClickNamesThePrimaryOrTheSplitByItsOwnDirectory() throws {
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/w/app"))
        store.toggleSplit(session.id)
        session.splitCwd = "/w/lib"
        let split = try #require(session.splitPaneIdentity)

        #expect(store.forwardedClickPane(session.id, pane: session.paneIdentity) == ForwardedClickPane(cwd: "/w/app"))
        #expect(store.forwardedClickPane(session.id, pane: split) == ForwardedClickPane(cwd: "/w/lib"))
    }

    @Test func anUnknownPaneOrSessionNamesNothing() throws {
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/w/app"))

        #expect(store.forwardedClickPane(session.id, pane: UUID()) == nil)
        #expect(store.forwardedClickPane(UUID(), pane: session.paneIdentity) == nil)
    }
}
