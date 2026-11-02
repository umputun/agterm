import Dispatch
import Foundation
@testable import agtermctlKit

// stage markers go to AGTERM_PROBE_LOG, so a timed-out test can tell which phase the probe reached
let stageLog = ProcessInfo.processInfo.environment["AGTERM_PROBE_LOG"]
func mark(_ stage: String) {
    guard let stageLog, let handle = FileHandle(forWritingAtPath: stageLog) else { return }
    handle.seekToEndOfFile()
    handle.write(Data("\(DispatchTime.now().uptimeNanoseconds / 1_000_000) \(stage)\n".utf8))
    try? handle.close()
}
mark("main entered pid=\(getpid())")

// exhausts the global queue's worker pool in its own process, then arms a SessionWaitWatchdog.
// exits 0 when the watchdog fires while the pool stays stalled, 1 when it does not fire, and 3 when
// a canary queued on the global queue ran, which means the pool was not exhausted for the whole run.
let release = DispatchSemaphore(value: 0)
for _ in 0..<200 { DispatchQueue.global().async { release.wait() } }
mark("blockers queued")
Thread.sleep(forTimeInterval: 0.5)

let canaryRan = DispatchSemaphore(value: 0)
DispatchQueue.global().async { canaryRan.signal() }
if canaryRan.wait(timeout: .now() + 0.5) == .success { mark("calling exit(3) early"); exit(3) }
mark("canary blocked")

let fired = DispatchSemaphore(value: 0)
let watchdog = SessionWaitWatchdog(seconds: 0.05) { fired.signal() }
mark("watchdog armed")
let result = withExtendedLifetime(watchdog) { fired.wait(timeout: .now() + 3) }
mark("watchdog wait \(result == .success ? "fired" : "timed out")")
if canaryRan.wait(timeout: .now()) == .success { mark("calling exit(3) late"); exit(3) }
mark("calling exit(\(result == .success ? 0 : 1))")
exit(result == .success ? 0 : 1)
