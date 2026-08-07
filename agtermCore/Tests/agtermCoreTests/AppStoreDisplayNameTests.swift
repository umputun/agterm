import Foundation
import Testing
@testable import agtermCore

/// Name resolution behind the sidebar's "Copy Name" context-menu item: the labels it copies come from
/// `displayName`, so they match what the row shows rather than the stored `customName`.
@MainActor
struct AppStoreDisplayNameTests {
    @Test func sessionDisplayNamesPrefersTheRenameOverTheCwdBasename() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let renamed = store.addSession(toWorkspace: ws.id, cwd: "/tmp/alpha")!
        let plain = store.addSession(toWorkspace: ws.id, cwd: "/tmp/beta")!
        store.renameSession(renamed.id, to: "🌱 feature-branch")
        // the renamed one reads back its label; the un-renamed one falls through to the cwd basename,
        // which is what its row displays.
        #expect(store.sessionDisplayNames([renamed.id, plain.id]) == ["🌱 feature-branch", "beta"])
    }

    @Test func sessionDisplayNamesKeepsTheGivenOrder() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = store.addSession(toWorkspace: ws.id, cwd: "/tmp/one")!
        let second = store.addSession(toWorkspace: ws.id, cwd: "/tmp/two")!
        // the menu passes sidebar-selection order, so the copied block must not be re-sorted.
        #expect(store.sessionDisplayNames([second.id, first.id]) == ["two", "one"])
    }

    @Test func sessionDisplayNamesSkipsSessionsThatAreGone() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let live = store.addSession(toWorkspace: ws.id, cwd: "/tmp/live")!
        // a row closed between the right-click and the menu choice: skipped, not a crash and not a blank
        // line in the middle of the copied block.
        #expect(store.sessionDisplayNames([live.id, UUID()]) == ["live"])
    }

    @Test func sessionDisplayNamesIsEmptyWhenEveryIdIsGone() {
        let store = makeStore()
        // the menu action leaves the pasteboard untouched on empty, rather than clearing what the user had.
        #expect(store.sessionDisplayNames([UUID(), UUID()]).isEmpty)
    }

    @Test func workspaceNameReadsBackTheRename() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        #expect(store.workspaceName(ws.id) == "work")
        store.renameWorkspace(ws.id, to: "Zumino")
        #expect(store.workspaceName(ws.id) == "Zumino")
    }

    @Test func workspaceNameIsNilForAnUnknownID() {
        let store = makeStore()
        #expect(store.workspaceName(UUID()) == nil)
    }
}
