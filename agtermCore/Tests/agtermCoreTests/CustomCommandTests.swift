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
        // a recognized token whose context value is empty (missing) substitutes to "".
        let ctx = CommandContext(sessionPWD: "/tmp")
        #expect(ctx.expand("[{AGT_SELECTION}]") == "[]")
        #expect(ctx.expand("cd {AGT_SESSION_PWD}") == "cd /tmp")
    }

    @Test func expandLeavesUnknownBracesUntouched() {
        // not one of the AGT_X tokens — left as-is so unrelated shell braces survive.
        let ctx = sampleContext()
        #expect(ctx.expand("echo {FOO} ${BAR}") == "echo {FOO} ${BAR}")
    }

    @Test func expandNoTokensIsIdentity() {
        let ctx = sampleContext()
        #expect(ctx.expand("git status") == "git status")
        #expect(ctx.expand("") == "")
    }

    @Test func expandDoesNotReSubstituteTokenInsideAValue() {
        // a token's value that contains another token's literal text must survive verbatim — the
        // single-pass scan never re-substitutes already-replaced text (no injection via a value).
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
        // an unspecified pane is the main pane — always a valid `session.type --pane` argument, so a
        // split-less session's context still round-trips into a pane-addressed control call. The typed
        // `Pane` enum guarantees the value is left/right/scratch by construction; its rawValue feeds the token.
        #expect(CommandContext().pane == .left)
        #expect(CommandContext().environment()["AGT_PANE"] == "left")
        #expect(CommandContext().expand("{AGT_PANE}") == "left")
        #expect(CommandContext(pane: .right).expand("{AGT_PANE}") == "right")
    }

    @Test func paneScratchExpandsToScratch() {
        // the scratch is a pane too — a chord fired from the session's scratch terminal reports
        // `scratch`, which round-trips straight back through `session type --pane scratch`.
        let ctx = CommandContext(pane: .scratch)
        #expect(ctx.pane == .scratch)
        #expect(ctx.environment()["AGT_PANE"] == "scratch")
        #expect(ctx.expand("{AGT_PANE}") == "scratch")
    }

    @Test func environmentKeySetMatchesTheTokensExpandSubstitutes() {
        // the symmetric guarantee: every env key is a token expand replaces, and vice versa.
        let ctx = sampleContext()
        let envKeys = Set(ctx.environment().keys)
        for key in envKeys {
            // the key, wrapped as a token, must be substituted out by expand.
            #expect(!ctx.expand("{\(key)}").contains("{"))
        }
        // and there is no extra token expand handles that environment omits.
        let expected: Set<String> = ["AGT_SESSION_ID", "AGT_SESSION_NAME", "AGT_SESSION_PWD",
                                     "AGT_WORKSPACE_ID", "AGT_WORKSPACE_NAME", "AGT_WINDOW_ID",
                                     "AGT_WINDOW_NAME", "AGT_PANE", "AGT_SELECTION", "AGT_SOCKET"]
        #expect(envKeys == expected)
    }

    @Test func tokenNamesMatchTheExpansionTokenSet() {
        // the public token-name list (used by the Settings token reference) must stay equal to the
        // set of tokens expand/environment handle, so the UI can't list a stale or missing token.
        let names = CommandContext.tokenNames
        #expect(Set(names) == Set(sampleContext().environment().keys))
        // every advertised name must actually substitute out via expand.
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
