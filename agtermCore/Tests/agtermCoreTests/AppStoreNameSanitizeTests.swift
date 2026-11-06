import Foundation
import Testing
@testable import agtermCore

/// Control-character sanitizing on every store arm whose value reaches a `{AGT_*}` custom-command
/// token (#347); see TerminalText.
@MainActor
struct AppStoreNameSanitizeTests {
    @Test func addSessionStripsInteriorControlCharactersFromNameAndCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try! #require(store.addSession(toWorkspace: ws.id,
                                                     cwd: "/work\ntouch /tmp/pwned",
                                                     name: "demo\ntouch /tmp/pwned"))
        #expect(session.customName == "demotouch /tmp/pwned")
        #expect(session.initialCwd == "/worktouch /tmp/pwned")
        #expect(session.effectiveCwd == "/worktouch /tmp/pwned")
    }

    @Test func listLabelNamesACompanionAfterItsParent() throws {
        let g = try CompanionGroup()
        g.store.renameSession(g.parent.id, to: "api")
        g.store.renameSession(g.first.id, to: "logs")

        #expect(g.store.listLabel(for: g.parent) == "api")
        #expect(g.store.listLabel(for: g.first) == "api › logs")
        #expect(g.store.listLabel(for: g.after) == g.after.displayName)

        g.store.renameSession(g.parent.id, to: "web")
        #expect(g.store.listLabel(for: g.first) == "web › logs")
    }

    @Test func listOrderKeepsEachGroupTogetherUnderIdenticallyNamedParents() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let zeta = try #require(store.addSession(toWorkspace: work.id, cwd: "/z", name: "zeta"))
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a", name: "api"))
        let second = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", name: "api"))
        let firstChild = try store.addCompanion(to: first.id, options: CompanionOptions(name: "zz")).get()
        let secondChild = try store.addCompanion(to: second.id, options: CompanionOptions(name: "aa")).get()

        let order = store.listOrdered(store.workspaces[0].sessions).map(\.id)

        #expect(order == [first.id, firstChild.id, second.id, secondChild.id, zeta.id])
    }

    @Test func aCompanionListedAheadOfItsParentStillFollowsIt() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a", name: "api"))
        let second = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", name: "api"))
        let firstChild = try store.addCompanion(to: first.id, options: CompanionOptions(name: "a")).get()
        let secondChild = try store.addCompanion(to: second.id, options: CompanionOptions(name: "b")).get()

        let order = store.listOrdered([firstChild, first, second, secondChild]).map(\.id)

        #expect(order == [first.id, firstChild.id, second.id, secondChild.id])
    }

    @Test func aCompanionListedWithoutItsParentSortsOnItsOwnLabel() throws {
        let g = try CompanionGroup()
        g.store.renameSession(g.parent.id, to: "m")
        g.store.renameSession(g.after.id, to: "a")
        g.store.renameSession(g.first.id, to: "c")

        #expect(g.store.listOrdered([g.first, g.after]).map(\.id) == [g.after.id, g.first.id])
    }

    @Test func renameSessionStripsInteriorControlCharacters() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.renameSession(session.id, to: "  demo\ntouch /tmp/pwned  ")
        #expect(session.customName == "demotouch /tmp/pwned")
    }

    @Test func addWorkspaceStripsInteriorControlCharacters() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "prod\ntouch /tmp/pwned")
        #expect(ws.name == "prodtouch /tmp/pwned")
    }

    @Test func renameWorkspaceStripsInteriorControlCharacters() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.renameWorkspace(ws.id, to: "prod\ntouch /tmp/pwned")
        #expect(store.workspaces[0].name == "prodtouch /tmp/pwned")
    }

    @Test func workspaceNamedSanitizesTheNeedle() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "prod\ntouch /tmp/pwned")
        #expect(store.workspace(named: "prod\ntouch /tmp/pwned")?.id == ws.id)
    }

    @Test func ensureWorkspaceWithControlCharacterNameStaysIdempotent() {
        let store = makeStore()
        let first = try! #require(store.ensureWorkspace(named: "prod\ntouch /tmp/pwned"))
        let second = try! #require(store.ensureWorkspace(named: "prod\ntouch /tmp/pwned"))
        #expect(second.id == first.id)
        #expect(store.workspaces.filter { $0.name == "prodtouch /tmp/pwned" }.count == 1)
        // blank gate runs after sanitizing, so a control-char-only name is nil, not a new empty workspace.
        #expect(store.ensureWorkspace(named: "\u{07}") == nil)
    }

    @Test func workspaceNameTreatsABlankAsAbsent() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        #expect(store.workspaceName(ws.id) == "work")
        // renameWorkspace rejects blank; AppStore+PendingClose rebuilds from a snapshot without that gate.
        store.workspaces[0].name = "   "
        #expect(store.workspaceName(ws.id) == nil)
    }
}
