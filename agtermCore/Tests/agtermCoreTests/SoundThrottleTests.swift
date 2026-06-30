import Testing
@testable import agtermCore

// `allow` is mutating, and the #expect macro captures its argument immutably, so each call is bound to a
// `let` before asserting rather than invoked inline.
struct SoundThrottleTests {
    @Test func firstPlayOfANameIsAllowed() {
        var throttle = SoundThrottle(window: .milliseconds(200))
        let first = throttle.allow("Ping", at: ContinuousClock().now)
        #expect(first)
    }

    @Test func sameSoundSuppressedWithinWindow() {
        var throttle = SoundThrottle(window: .milliseconds(200))
        let t0 = ContinuousClock().now
        let first = throttle.allow("Ping", at: t0)
        let early = throttle.allow("Ping", at: t0 + .milliseconds(1))
        let nearEdge = throttle.allow("Ping", at: t0 + .milliseconds(199))
        #expect(first)
        #expect(!early)
        #expect(!nearEdge)
    }

    @Test func sameSoundAllowedAtOrPastWindowBoundary() {
        var throttle = SoundThrottle(window: .milliseconds(200))
        let t0 = ContinuousClock().now
        let first = throttle.allow("Ping", at: t0)
        let atBoundary = throttle.allow("Ping", at: t0 + .milliseconds(200)) // >= window plays
        let wellPast = throttle.allow("Ping", at: t0 + .milliseconds(450))
        #expect(first)
        #expect(atBoundary)
        #expect(wellPast)
    }

    @Test func differentSoundsThrottleIndependently() {
        var throttle = SoundThrottle(window: .milliseconds(200))
        let t0 = ContinuousClock().now
        let ping = throttle.allow("Ping", at: t0)
        let hero = throttle.allow("Hero", at: t0 + .milliseconds(10))  // different name, not suppressed
        let pingAgain = throttle.allow("Ping", at: t0 + .milliseconds(20)) // Ping still inside its window
        let heroAgain = throttle.allow("Hero", at: t0 + .milliseconds(30)) // Hero now inside its window
        #expect(ping)
        #expect(hero)
        #expect(!pingAgain)
        #expect(!heroAgain)
    }

    @Test func suppressedReplayDoesNotAdvanceTheWindow() {
        // the window is measured from the last ALLOWED play, not the last attempt — a suppressed call
        // must not re-stamp, else a steady stream just under the window would never play.
        var throttle = SoundThrottle(window: .milliseconds(200))
        let t0 = ContinuousClock().now
        let first = throttle.allow("Ping", at: t0)
        let suppressed = throttle.allow("Ping", at: t0 + .milliseconds(150)) // must not re-stamp
        let atBoundary = throttle.allow("Ping", at: t0 + .milliseconds(200)) // 200ms since ALLOWED play → plays
        #expect(first)
        #expect(!suppressed)
        #expect(atBoundary)
    }
}
