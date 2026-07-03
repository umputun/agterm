import Testing
@testable import agtermCore

struct ClipboardPromptPolicyTests {
    @Test func defaultsToPromptForBothDirections() {
        let policy = ClipboardPromptPolicy()
        #expect(policy.decision(for: .read) == .prompt)
        #expect(policy.decision(for: .write) == .prompt)
    }

    @Test func rememberAllowMakesDirectionAllow() {
        var policy = ClipboardPromptPolicy()
        policy.remember(.read, allow: true)
        #expect(policy.decision(for: .read) == .allow)
    }

    @Test func rememberDenyMakesDirectionDeny() {
        var policy = ClipboardPromptPolicy()
        policy.remember(.write, allow: false)
        #expect(policy.decision(for: .write) == .deny)
    }

    @Test func directionsAreIndependent() {
        var policy = ClipboardPromptPolicy()
        policy.remember(.read, allow: true)
        #expect(policy.decision(for: .read) == .allow)
        #expect(policy.decision(for: .write) == .prompt)
    }

    @Test func rememberingWriteLeavesReadPrompting() {
        var policy = ClipboardPromptPolicy()
        policy.remember(.write, allow: false)
        #expect(policy.decision(for: .write) == .deny)
        #expect(policy.decision(for: .read) == .prompt)
    }

    @Test func laterRememberOverridesEarlier() {
        var policy = ClipboardPromptPolicy()
        policy.remember(.read, allow: true)
        policy.remember(.read, allow: false)
        #expect(policy.decision(for: .read) == .deny)
    }
}
