import Testing
@testable import agtermCore

struct QuitPromptTests {
    @Test func singleWindowSingleSession() {
        #expect(QuitPrompt.message(windows: 1, sessions: 1) == "This closes 1 window and 1 session, ending all running shells.")
    }

    @Test func singleWindowManySessions() {
        #expect(QuitPrompt.message(windows: 1, sessions: 3) == "This closes 1 window and 3 sessions, ending all running shells.")
    }

    @Test func manyWindowsManySessions() {
        #expect(QuitPrompt.message(windows: 2, sessions: 5) == "This closes 2 windows and 5 sessions, ending all running shells.")
    }
}
