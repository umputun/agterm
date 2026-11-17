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

    @Test(arguments: [
        RestartCase(1, false, .live, .live, false, "1 session keeps running and reconnects after the restart."),
        RestartCase(3, false, .live, .live, false, "3 sessions keep running and reconnect after the restart."),
        RestartCase(3, false, .live, .live, true, "3 sessions keep running. Reopen agterm with the same AGTERM_STATE_DIR to reconnect."),
        RestartCase(1, false, .live, .none, false, "1 session ends at the next launch."),
        RestartCase(2, false, .live, .rerun, false, "2 sessions end at the next launch."),
        RestartCase(2, false, .live, .none, true, "2 sessions end when agterm next opens this state directory."),
        RestartCase(1, false, .none, .live, false, "This ends the running shells in 1 session."),
        RestartCase(4, false, .rerun, .rerun, false, "This ends the running shells in 4 sessions."),
        RestartCase(0, true, .none, .none, false, "Sessions from other hosts keep running there and reconnect after the restart."),
        RestartCase(0, true, .live, .live, true, "Sessions from other hosts keep running there. Reopen agterm with the same AGTERM_STATE_DIR to reconnect."),
        RestartCase(2, true, .live, .live, false,
         "2 sessions keep running and reconnect after the restart. Sessions from other hosts keep running there and reconnect after the restart."),
        RestartCase(2, true, .none, .none, false, "This ends the running shells in 2 sessions. Sessions from other hosts keep running there and reconnect after the restart."),
        RestartCase(0, false, .live, .live, true, ""),
    ])
    func restartMessage(_ c: RestartCase) {
        #expect(QuitPrompt.restartMessage(localSessions: c.local, remote: c.remote, current: c.current, next: c.next,
                                          customStateDirectory: c.custom) == c.expected)
    }

    struct RestartCase: Sendable {
        let local: Int, remote: Bool, current: RestoreMode, next: RestoreMode, custom: Bool, expected: String
        init(_ local: Int, _ remote: Bool, _ current: RestoreMode, _ next: RestoreMode, _ custom: Bool, _ expected: String) {
            (self.local, self.remote, self.current, self.next, self.custom, self.expected) = (local, remote, current, next, custom, expected)
        }
    }
}
