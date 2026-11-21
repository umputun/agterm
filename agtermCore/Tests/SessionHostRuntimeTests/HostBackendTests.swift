import Darwin
import Foundation
import Testing
@testable import SessionHostRuntime

struct HostBackendTests {
    private final class Signals: @unchecked Sendable {
        var sent: [Int32] = []
    }

    @Test func terminateReapsAChildThatWritesWhileStoppingWithoutKillingIt() throws {
        let script = "trap 'head -c 65536 /dev/zero | tr \"\\\\0\" x; exit 0' TERM; printf ready; while :; do sleep 0.02; done"
        let process = try PTYProcess.spawn(argv: ["/bin/sh", "-c", script], env: ["PATH": "/usr/bin:/bin"], cwd: "/tmp", rows: 24, cols: 80)
        let signals = Signals()
        let child = NativeHostChild(process, signal: { pid, code in
            signals.sent.append(code)
            return kill(pid, code)
        })
        defer { if !child.hasExited { try? child.terminate(grace: 2) } }
        var seen = ""
        var bytes = [UInt8](repeating: 0, count: 256)
        while !seen.contains("ready") {
            var ready = pollfd(fd: process.ptyFD, events: Int16(POLLIN), revents: 0)
            try #require(poll(&ready, 1, 10_000) == 1)
            let count = read(process.ptyFD, &bytes, bytes.count)
            try #require(count > 0)
            seen += String(decoding: bytes.prefix(count), as: UTF8.self)
        }

        try child.terminate(grace: 10)

        #expect(signals.sent == [SIGTERM])
        #expect(child.hasExited)
        #expect(child.stopReason?.contains("exited with wait status 0") == true)
    }
}
