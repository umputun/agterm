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
