import Foundation
import Testing
@testable import agtermCore

struct CustomCommandTests {
    private func sampleContext() -> CommandContext {
        CommandContext(sessionID: "sess-1", sessionName: "shell", sessionPWD: "/tmp/work",
                       workspaceID: "ws-1", workspaceName: "main", windowID: "win-1",
                       windowName: "work", pane: .right, selection: "hello", socket: "/tmp/agt.sock")
    }

    @Test func expandSubstitutesKnownTokens() {
        let ctx = sampleContext()
        #expect(ctx.expand("open {AGT_SESSION_PWD}") == "open /tmp/work")
        #expect(ctx.expand("{AGT_WINDOW_NAME}/{AGT_WORKSPACE_NAME}") == "work/main")
    }

    @Test func expandRepeatsToken() {
        let ctx = sampleContext()
        #expect(ctx.expand("{AGT_SESSION_ID} {AGT_SESSION_ID}") == "sess-1 sess-1")
    }

    @Test func expandEmptyTokenValueBecomesEmptyString() {
        let ctx = CommandContext(sessionPWD: "/tmp")
        #expect(ctx.expand("[{AGT_SELECTION}]") == "[]")
        #expect(ctx.expand("cd {AGT_SESSION_PWD}") == "cd /tmp")
    }

    @Test func expandLeavesUnknownBracesUntouched() {
        let ctx = sampleContext()
        #expect(ctx.expand("echo {FOO} ${BAR}") == "echo {FOO} ${BAR}")
    }

    @Test func expandNoTokensIsIdentity() {
        let ctx = sampleContext()
        #expect(ctx.expand("git status") == "git status")
        #expect(ctx.expand("") == "")
    }

    @Test func expandDoesNotReSubstituteTokenInsideAValue() {
        // the single-pass scan never re-substitutes replaced text, so a value cannot inject a token.
        let ctx = CommandContext(selection: "{AGT_SOCKET}", socket: "/tmp/agt.sock")
        #expect(ctx.expand("echo {AGT_SELECTION}") == "echo {AGT_SOCKET}")
        #expect(ctx.expand("{AGT_SELECTION} {AGT_SOCKET}") == "{AGT_SOCKET} /tmp/agt.sock")
    }

    @Test func expandLeavesUnclosedBraceUntouched() {
        let ctx = sampleContext()
        #expect(ctx.expand("echo {AGT_SESSION_ID") == "echo {AGT_SESSION_ID")
    }

    @Test func environmentHasAllTokenKeysAndValues() {
        let env = sampleContext().environment()
        #expect(env["AGT_SESSION_ID"] == "sess-1")
        #expect(env["AGT_SESSION_NAME"] == "shell")
        #expect(env["AGT_SESSION_PWD"] == "/tmp/work")
        #expect(env["AGT_WORKSPACE_ID"] == "ws-1")
        #expect(env["AGT_WORKSPACE_NAME"] == "main")
        #expect(env["AGT_WINDOW_ID"] == "win-1")
        #expect(env["AGT_WINDOW_NAME"] == "work")
        #expect(env["AGT_PANE"] == "right")
        #expect(env["AGT_SELECTION"] == "hello")
        #expect(env["AGT_SOCKET"] == "/tmp/agt.sock")
        #expect(env.count == 10)
    }

    @Test func paneDefaultsToLeft() {
        // the default must stay a valid `session.type --pane` value, so a split-less session's context
        // still round-trips into a pane-addressed control call.
        #expect(CommandContext().pane == .left)
        #expect(CommandContext().environment()["AGT_PANE"] == "left")
        #expect(CommandContext().expand("{AGT_PANE}") == "left")
        #expect(CommandContext(pane: .right).expand("{AGT_PANE}") == "right")
    }

    @Test func paneScratchExpandsToScratch() {
        let ctx = CommandContext(pane: .scratch)
        #expect(ctx.pane == .scratch)
        #expect(ctx.environment()["AGT_PANE"] == "scratch")
        #expect(ctx.expand("{AGT_PANE}") == "scratch")
    }

    @Test func referencesSessionScopedContextDetectsSessionTokensButNotLaunchers() {
        #expect(CommandContext.referencesSessionScopedContext("echo {AGT_SESSION_PWD}"))
        #expect(CommandContext.referencesSessionScopedContext(#"rm -rf "$AGT_SESSION_PWD"/*"#))
        #expect(CommandContext.referencesSessionScopedContext("echo ${AGT_WORKSPACE_NAME}"))
        #expect(CommandContext.referencesSessionScopedContext("printf %s {AGT_SELECTION}"))
        // launcher tokens (socket/window/pane) must not count, so a launcher stays firable.
        #expect(!CommandContext.referencesSessionScopedContext(#"agtermctl session new --command "ssh work""#))
        #expect(!CommandContext.referencesSessionScopedContext("agtermctl --socket {AGT_SOCKET} session new"))
        #expect(!CommandContext.referencesSessionScopedContext("open -a Safari {AGT_WINDOW_ID} {AGT_PANE}"))
    }

    @Test func environmentKeySetMatchesTheTokensExpandSubstitutes() {
        let ctx = sampleContext()
        let envKeys = Set(ctx.environment().keys)
        for key in envKeys {
            #expect(!ctx.expand("{\(key)}").contains("{"))
        }
        let expected: Set<String> = ["AGT_SESSION_ID", "AGT_SESSION_NAME", "AGT_SESSION_PWD",
                                     "AGT_WORKSPACE_ID", "AGT_WORKSPACE_NAME", "AGT_WINDOW_ID",
                                     "AGT_WINDOW_NAME", "AGT_PANE", "AGT_SELECTION", "AGT_SOCKET"]
        #expect(envKeys == expected)
    }

    @Test func tokenNamesMatchTheExpansionTokenSet() {
        // the list feeds the Settings token reference, so a stale or missing name would show up there.
        let names = CommandContext.tokenNames
        #expect(Set(names) == Set(sampleContext().environment().keys))
        let ctx = sampleContext()
        for name in names {
            #expect(!ctx.expand("{\(name)}").contains("{"))
        }
    }

    @Test func customCommandCodableRoundTrips() throws {
        let original = CustomCommand(name: "Zed", command: "open -a Zed {AGT_SESSION_PWD}", shortcut: "cmd+shift+e")
        let decoded = try JSONDecoder().decode(CustomCommand.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
