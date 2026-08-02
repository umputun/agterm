import Foundation
import Testing
@testable import agtermCore

/// Control-character sanitizing on every store arm whose value reaches a `{AGT_*}` custom-command token —
/// those expand unquoted into `/bin/sh -c`, so an interior newline is a statement separator (#347).
/// Split out of `AppStoreTests` for the line budget.
@MainActor
struct AppStoreNameSanitizeTests {
    @Test func addSessionStripsInteriorControlCharactersFromNameAndCwd() {
        // name → {AGT_SESSION_NAME} and cwd → {AGT_SESSION_PWD} both expand unquoted into /bin/sh -c.
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
        // customName reaches {AGT_SESSION_NAME}, unquoted into /bin/sh -c; surrounding whitespace still trims.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.renameSession(session.id, to: "  demo\ntouch /tmp/pwned  ")
        #expect(session.customName == "demotouch /tmp/pwned")
    }

    @Test func addWorkspaceStripsInteriorControlCharacters() {
        // {AGT_WORKSPACE_NAME} expands unquoted into /bin/sh -c; `workspace new --name` must not store the newline.
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
        // the lookup must match the sanitized stored name, or `session.new --workspace-name` (without
        // --create-workspace) reads back as "workspace not found" against a name the caller just created.
        let store = makeStore()
        let ws = store.addWorkspace(name: "prod\ntouch /tmp/pwned")
        #expect(store.workspace(named: "prod\ntouch /tmp/pwned")?.id == ws.id)
    }

    @Test func ensureWorkspaceWithControlCharacterNameStaysIdempotent() {
        // needle and stored name sanitize alike, so the second call reuses instead of appending a twin.
        let store = makeStore()
        let first = try! #require(store.ensureWorkspace(named: "prod\ntouch /tmp/pwned"))
        let second = try! #require(store.ensureWorkspace(named: "prod\ntouch /tmp/pwned"))
        #expect(second.id == first.id)
        #expect(store.workspaces.filter { $0.name == "prodtouch /tmp/pwned" }.count == 1)
        // a control-char-only name sanitizes to blank BEFORE the blank gate — nil, not an
        // unmatchable empty-named workspace appended on every call.
        #expect(store.ensureWorkspace(named: "\u{07}") == nil)
    }
}
