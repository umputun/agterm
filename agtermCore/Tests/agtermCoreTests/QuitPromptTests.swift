import Testing
@testable import agtermCore

struct QuitPromptTests {
    @Test func singleWindowSingleSession() {
        #expect(QuitPrompt.message(windows: 1, sessions: 1, mode: .none) == "This closes 1 window and 1 session, ending all running shells.")
    }

    @Test func singleWindowManySessions() {
        #expect(QuitPrompt.message(windows: 1, sessions: 3, mode: .none) == "This closes 1 window and 3 sessions, ending all running shells.")
    }

    @Test func manyWindowsManySessions() {
        #expect(QuitPrompt.message(windows: 2, sessions: 5, mode: .none) == "This closes 2 windows and 5 sessions, ending all running shells.")
    }

    @Test func rerunModeKeepsShellClause() {
        #expect(QuitPrompt.message(windows: 1, sessions: 1, mode: .rerun) == "This closes 1 window and 1 session, ending all running shells.")
    }

    @Test func liveModeDropsShellClause() {
        #expect(QuitPrompt.message(windows: 1, sessions: 18, mode: .live) == "This closes 1 window and 18 sessions.")
    }

    @Test func liveModePluralizesWindows() {
        #expect(QuitPrompt.message(windows: 2, sessions: 1, mode: .live) == "This closes 2 windows and 1 session.")
    }

    @Test(arguments: [RestoreMode.none, .rerun])
    func windowCloseNonLiveEndsSessions(mode: RestoreMode) {
        #expect(QuitPrompt.windowCloseMessage(sessions: 1, mode: mode)
            == "This ends 1 running session. The window can be reopened from File ▸ Open Window.")
        #expect(QuitPrompt.windowCloseMessage(sessions: 4, mode: mode)
            == "This ends 4 running sessions. The window can be reopened from File ▸ Open Window.")
    }

    @Test func windowCloseLiveDropsEndingClaim() {
        #expect(QuitPrompt.windowCloseMessage(sessions: 1, mode: .live)
            == "This closes 1 session. The window can be reopened from File ▸ Open Window.")
        #expect(QuitPrompt.windowCloseMessage(sessions: 9, mode: .live)
            == "This closes 9 sessions. The window can be reopened from File ▸ Open Window.")
    }
}
