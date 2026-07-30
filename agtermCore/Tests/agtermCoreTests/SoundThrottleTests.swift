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
        let atBoundary = throttle.allow("Ping", at: t0 + .milliseconds(200))
        let wellPast = throttle.allow("Ping", at: t0 + .milliseconds(450))
        #expect(first)
        #expect(atBoundary)
        #expect(wellPast)
    }

    @Test func differentSoundsThrottleIndependently() {
        var throttle = SoundThrottle(window: .milliseconds(200))
        let t0 = ContinuousClock().now
        let ping = throttle.allow("Ping", at: t0)
        let hero = throttle.allow("Hero", at: t0 + .milliseconds(10))
        let pingAgain = throttle.allow("Ping", at: t0 + .milliseconds(20))
        let heroAgain = throttle.allow("Hero", at: t0 + .milliseconds(30))
        #expect(ping)
        #expect(hero)
        #expect(!pingAgain)
        #expect(!heroAgain)
    }

    @Test func suppressedReplayDoesNotAdvanceTheWindow() {
        // measured from the last ALLOWED play, not the last attempt — else a steady stream just under the
        // window would never play.
        var throttle = SoundThrottle(window: .milliseconds(200))
        let t0 = ContinuousClock().now
        let first = throttle.allow("Ping", at: t0)
        let suppressed = throttle.allow("Ping", at: t0 + .milliseconds(150))
        let atBoundary = throttle.allow("Ping", at: t0 + .milliseconds(200))
        #expect(first)
        #expect(!suppressed)
        #expect(atBoundary)
    }
}
