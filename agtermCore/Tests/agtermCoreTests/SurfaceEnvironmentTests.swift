import Foundation
import Testing
@testable import agtermCore

struct SurfaceEnvironmentTests {
    @Test func terminalIdentityBelongsToAgterm() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let sessionEnv = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: windowID,
            workspaceID: nil,
            socketPath: "/tmp/agterm.sock",
            programVersion: "0.12.0"
        )
        let quickEnv = SurfaceEnvironment.quickTerminal(
            windowID: windowID,
            socketPath: "/tmp/agterm.sock",
            programVersion: "0.12.0"
        )

        for env in [sessionEnv, quickEnv] {
            #expect(env["TERM_PROGRAM"] == "agterm")
            #expect(env["TERM_PROGRAM_VERSION"] == "0.12.0")
        }
    }

    @Test func sessionEnvironmentCarriesAllKnownIdentifiers() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: windowID,
            workspaceID: workspaceID,
            socketPath: "/tmp/agterm.sock",
            programVersion: "0.12.0"
        )

        #expect(env == [
            "AGTERM_ENABLED": "1",
            "AGTERM_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "AGTERM_WINDOW_ID": "22222222-2222-2222-2222-222222222222",
            "AGTERM_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
            "AGTERM_SOCKET": "/tmp/agterm.sock",
            "TERM_PROGRAM": "agterm",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
    }

    @Test func sessionEnvironmentOmitsUnknownWindowAndWorkspace() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/agterm.sock",
            programVersion: "0.12.0"
        )

        #expect(env == [
            "AGTERM_ENABLED": "1",
            "AGTERM_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "AGTERM_SOCKET": "/tmp/agterm.sock",
            "TERM_PROGRAM": "agterm",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
    }

    @Test(arguments: [
        (StatusPane.left, "left"),
        (StatusPane.right, "right"),
        (StatusPane.scratch, "scratch"),
    ])
    func sessionEnvironmentInjectsPaneWhenGiven(pane: StatusPane, expected: String) {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/agterm.sock",
            programVersion: "0.12.0",
            pane: pane
        )

        #expect(env["AGTERM_PANE"] == expected)
        // pane injection must not disturb the existing identifiers
        #expect(env["AGTERM_ENABLED"] == "1")
        #expect(env["AGTERM_SESSION_ID"] == "11111111-1111-1111-1111-111111111111")
        #expect(env["AGTERM_SOCKET"] == "/tmp/agterm.sock")
    }

    @Test func sessionEnvironmentOmitsPaneWhenNil() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: windowID,
            workspaceID: workspaceID,
            socketPath: "/tmp/agterm.sock",
            programVersion: "0.12.0",
            pane: nil
        )

        #expect(env["AGTERM_PANE"] == nil)
        // the full identifier set is unchanged when no pane is given
        #expect(env == [
            "AGTERM_ENABLED": "1",
            "AGTERM_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "AGTERM_WINDOW_ID": "22222222-2222-2222-2222-222222222222",
            "AGTERM_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
            "AGTERM_SOCKET": "/tmp/agterm.sock",
            "TERM_PROGRAM": "agterm",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
    }

    @Test func sessionEnvironmentInjectsPaneTokenWhenGiven() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/agterm.sock",
            programVersion: "0.12.0",
            pane: .right,
            paneToken: "surface-token-abc"
        )

        #expect(env["AGTERM_PANE_ID"] == "surface-token-abc")
        // the token rides alongside the role, not instead of it
        #expect(env["AGTERM_PANE"] == "right")
    }

    @Test(arguments: [nil, ""])
    func sessionEnvironmentOmitsPaneTokenWhenNilOrEmpty(token: String?) {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/agterm.sock",
            programVersion: "0.12.0",
            pane: .left,
            paneToken: token
        )

        #expect(env["AGTERM_PANE_ID"] == nil)
    }

    @Test func quickTerminalEnvironmentOmitsSessionAndWorkspaceIdentifiers() {
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let env = SurfaceEnvironment.quickTerminal(
            windowID: windowID,
            socketPath: "/tmp/agterm.sock",
            programVersion: "0.12.0"
        )

        #expect(env == [
            "AGTERM_ENABLED": "1",
            "AGTERM_WINDOW_ID": "22222222-2222-2222-2222-222222222222",
            "AGTERM_SOCKET": "/tmp/agterm.sock",
            "TERM_PROGRAM": "agterm",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
        #expect(env["AGTERM_SESSION_ID"] == nil)
        #expect(env["AGTERM_WORKSPACE_ID"] == nil)
    }

    @Test func emptySocketPathIsStillEmitted() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "",
            programVersion: "0.12.0"
        )

        #expect(env["AGTERM_SOCKET"] == "")
    }
}
