import Dispatch
import Foundation
@testable import agtermctlKit

// exhausts the global queue's worker pool in its own process, then arms a SessionWaitWatchdog.
// exits 0 when the watchdog fires while the pool stays stalled, 1 when it does not fire, and 3 when
// a canary queued on the global queue ran, which means the pool was not exhausted for the whole run.
let release = DispatchSemaphore(value: 0)
for _ in 0..<200 { DispatchQueue.global().async { release.wait() } }
Thread.sleep(forTimeInterval: 0.5)

let canaryRan = DispatchSemaphore(value: 0)
DispatchQueue.global().async { canaryRan.signal() }
if canaryRan.wait(timeout: .now() + 0.5) == .success { exit(3) }

let fired = DispatchSemaphore(value: 0)
let watchdog = SessionWaitWatchdog(seconds: 0.05) { fired.signal() }
let result = withExtendedLifetime(watchdog) { fired.wait(timeout: .now() + 3) }
if canaryRan.wait(timeout: .now()) == .success { exit(3) }
exit(result == .success ? 0 : 1)
