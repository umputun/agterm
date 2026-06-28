import Testing
@testable import agtermCore

struct AgentStatusTests {
    @Test func rawValueRoundTrip() {
        #expect(AgentStatus(rawValue: "idle") == .idle)
        #expect(AgentStatus(rawValue: "active") == .active)
        #expect(AgentStatus(rawValue: "completed") == .completed)
        #expect(AgentStatus(rawValue: "blocked") == .blocked)
    }

    @Test func unknownRawValueIsNil() {
        #expect(AgentStatus(rawValue: "running") == nil)
        #expect(AgentStatus(rawValue: "") == nil)
        #expect(AgentStatus(rawValue: "Active") == nil) // case-sensitive
    }

    @Test func allCasesCoverAllStates() {
        #expect(AgentStatus.allCases == [.idle, .active, .completed, .blocked])
    }

    @Test func needsAttentionOnlyBlockedAndCompleted() {
        #expect(AgentStatus.blocked.needsAttention)
        #expect(AgentStatus.completed.needsAttention)
        #expect(!AgentStatus.idle.needsAttention)
        #expect(!AgentStatus.active.needsAttention)
    }

    @Test func clearedByKeystrokeClearsAttentionAlwaysAndActiveOnlyOnEscape() {
        // blocked/completed clear on ANY key — you've engaged with the prompt / finished result
        #expect(AgentStatus.blocked.clearedByKeystroke(isEscape: false))
        #expect(AgentStatus.blocked.clearedByKeystroke(isEscape: true))
        #expect(AgentStatus.completed.clearedByKeystroke(isEscape: false))
        #expect(AgentStatus.completed.clearedByKeystroke(isEscape: true))
        // active clears ONLY on Escape (the interrupt key); ordinary typing leaves the working glyph
        #expect(!AgentStatus.active.clearedByKeystroke(isEscape: false))
        #expect(AgentStatus.active.clearedByKeystroke(isEscape: true))
        // idle has no glyph to clear
        #expect(!AgentStatus.idle.clearedByKeystroke(isEscape: false))
        #expect(!AgentStatus.idle.clearedByKeystroke(isEscape: true))
    }

    @Test func indicatorDefaults() {
        let indicator = AgentIndicator()
        #expect(indicator.status == .idle)
        #expect(indicator.blink == false)
        #expect(indicator.autoReset == false)
    }

    @Test func indicatorCustomInit() {
        let indicator = AgentIndicator(status: .active, blink: true, autoReset: true)
        #expect(indicator.status == .active)
        #expect(indicator.blink == true)
        #expect(indicator.autoReset == true)
    }

    @Test func indicatorEquatableEqual() {
        #expect(AgentIndicator(status: .blocked, blink: true) == AgentIndicator(status: .blocked, blink: true))
        #expect(AgentIndicator() == AgentIndicator(status: .idle, blink: false, autoReset: false))
        #expect(AgentIndicator(status: .completed, autoReset: true) == AgentIndicator(status: .completed, autoReset: true))
    }

    @Test func indicatorEquatableNotEqual() {
        #expect(AgentIndicator(status: .active) != AgentIndicator(status: .completed))
        #expect(AgentIndicator(status: .active, blink: true) != AgentIndicator(status: .active, blink: false))
        #expect(AgentIndicator(status: .completed, autoReset: true) != AgentIndicator(status: .completed, autoReset: false))
    }
}
