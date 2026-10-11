import Testing
@testable import agtermCore

struct InputSourceLockTests {
    static let us = "com.apple.keylayout.US"
    static let ru = "com.apple.keylayout.Russian-Phonetic"
    static let enabled: Set<String> = [us, ru]

    @Test func engagingSelectsTheTargetAndRemembersTheEarlierSource() {
        var lock = InputSourceLock()
        #expect(lock.reconcile(terminalFocused: true, target: Self.us, enabled: Self.enabled, current: Self.ru) == Self.us)
        #expect(lock.baseline == Self.ru)
    }

    @Test func aManualSwitchWhileEngagedIsSwitchedBackAndTheBaselineKept() {
        var lock = InputSourceLock()
        _ = lock.reconcile(terminalFocused: true, target: Self.us, enabled: Self.enabled, current: Self.ru)
        #expect(lock.reconcile(terminalFocused: true, target: Self.us, enabled: Self.enabled, current: Self.us) == nil)
        #expect(lock.reconcile(terminalFocused: true, target: Self.us, enabled: Self.enabled, current: Self.ru) == Self.us)
        #expect(lock.baseline == Self.ru)
    }

    @Test func losingTerminalFocusRestoresTheEarlierSourceOnce() {
        var lock = InputSourceLock()
        _ = lock.reconcile(terminalFocused: true, target: Self.us, enabled: Self.enabled, current: Self.ru)
        #expect(lock.reconcile(terminalFocused: false, target: Self.us, enabled: Self.enabled, current: Self.us) == Self.ru)
        #expect(lock.baseline == nil)
        #expect(lock.reconcile(terminalFocused: false, target: Self.us, enabled: Self.enabled, current: Self.ru) == nil)
    }

    @Test func engagingOnTheTargetItselfSelectsNothingEitherWay() {
        var lock = InputSourceLock()
        #expect(lock.reconcile(terminalFocused: true, target: Self.us, enabled: Self.enabled, current: Self.us) == nil)
        #expect(lock.baseline == Self.us)
        #expect(lock.reconcile(terminalFocused: false, target: Self.us, enabled: Self.enabled, current: Self.us) == nil)
    }

    @Test func turningTheSettingOffWhileEngagedRestores() {
        var lock = InputSourceLock()
        _ = lock.reconcile(terminalFocused: true, target: Self.us, enabled: Self.enabled, current: Self.ru)
        #expect(lock.reconcile(terminalFocused: true, target: nil, enabled: Self.enabled, current: Self.us) == Self.ru)
        #expect(lock.baseline == nil)
    }

    @Test func changingTheTargetWhileEngagedKeepsTheOriginalBaseline() {
        let de = "com.apple.keylayout.German"
        var lock = InputSourceLock()
        let enabled = Self.enabled.union([de])
        _ = lock.reconcile(terminalFocused: true, target: Self.us, enabled: enabled, current: Self.ru)
        #expect(lock.reconcile(terminalFocused: true, target: de, enabled: enabled, current: Self.us) == de)
        #expect(lock.baseline == Self.ru)
    }

    @Test func aTargetMacOSCannotSelectEngagesNothing() {
        var lock = InputSourceLock()
        #expect(lock.reconcile(terminalFocused: true, target: "com.apple.keylayout.German", enabled: Self.enabled,
                               current: Self.ru) == nil)
        #expect(lock.baseline == nil)
    }

    @Test func aTargetDisabledWhileEngagedReleasesTheOverride() {
        var lock = InputSourceLock()
        _ = lock.reconcile(terminalFocused: true, target: Self.us, enabled: Self.enabled, current: Self.ru)
        #expect(lock.reconcile(terminalFocused: true, target: Self.us, enabled: [Self.ru], current: Self.us) == Self.ru)
        #expect(lock.baseline == nil)
    }

    @Test func aRefusedSelectionLeavesNothingToRestore() {
        var lock = InputSourceLock()
        _ = lock.reconcile(terminalFocused: true, target: Self.us, enabled: Self.enabled, current: Self.ru)
        lock.selectionFailed()
        #expect(lock.release(current: Self.ru) == nil)
    }
}
