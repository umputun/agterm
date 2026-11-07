import Foundation
import Testing
@testable import agtermCore

@MainActor
struct PooledForwardTests {
    @MainActor
    final class Runner {
        var calls: [[String]] = []
        var pid: Int32? = 100
        var forwardStatus: Int32 = 0
        var holdNextForward = false
        var held: CheckedContinuation<RemoteCommandResult, Never>?

        func run(_ argv: [String]) async -> RemoteCommandResult {
            calls.append(argv)
            switch argv[2] {
            case "forward":
                if holdNextForward {
                    holdNextForward = false
                    return await withCheckedContinuation { held = $0 }
                }
                return RemoteCommandResult(status: forwardStatus, stdout: "", stderr: "")
            case "check":
                guard let pid else { return RemoteCommandResult(status: 255, stdout: "", stderr: "No such file or directory") }
                return RemoteCommandResult(status: 0, stdout: "", stderr: "Master running (pid=\(pid))\r\n")
            default:
                return RemoteCommandResult(status: 0, stdout: "", stderr: "")
            }
        }

        var operations: [String] { calls.map { $0[2] } }

        func release() {
            held?.resume(returning: RemoteCommandResult(status: 0, stdout: "", stderr: ""))
            held = nil
        }
    }

    let runner = Runner()
    let pool = SshConnectionPool(host: "box", root: "/tmp", key: UUID().uuidString) { _ in 0 }
    let spec = "localhost:5001:localhost:3000"

    private func forward(_ events: Box) -> PooledForward {
        PooledForward(pool: pool, user: "forward:t", spec: spec, interval: .milliseconds(10),
                      runner: { [runner] in await runner.run($0) }, onEvent: { events.items.append($0) })
    }

    @MainActor
    final class Box {
        var items: [PortForwardEvent] = []
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aForwardIsAddedThroughTheConnectionAndCancelledThereBeforeItsLeaseIsReleased() async throws {
        let events = Box()
        let forward = forward(events)

        forward.start()
        #expect(await eventually { events.items == [.ready] })
        #expect(pool.load == [1])
        #expect(runner.calls.first == ["ssh", "-O", "forward", "-o", "ControlPath=" + pool.lease("probe"), "-L", spec, "box"])
        pool.release("probe")
        forward.stop()

        #expect(await eventually { runner.operations.last == "cancel" && pool.load == [0] })
    }

    @Test func aCloseWhileTheAddIsInFlightCancelsItOnceItLands() async throws {
        let events = Box()
        let forward = forward(events)
        runner.holdNextForward = true

        forward.start()
        #expect(await eventually { runner.held != nil })
        forward.stop()
        #expect(pool.load == [1])
        runner.release()

        #expect(await eventually { runner.operations == ["forward", "cancel"] })
        #expect(await eventually { pool.load == [0] })
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.operations == ["forward", "cancel"])
        #expect(events.items.isEmpty)
    }

    @Test func aConnectionAnotherUserReplacedGetsTheForwardAddedAgain() async throws {
        let events = Box()
        let forward = forward(events)
        forward.start()
        #expect(await eventually { events.items == [.ready] })

        runner.pid = 200

        #expect(await eventually { runner.operations.filter { $0 == "forward" }.count == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.operations.filter { $0 == "forward" }.count == 2)
        #expect(events.items == [.ready])
        forward.stop()
    }

    @Test func aConnectionThatCannotBeBroughtBackFailsTheForward() async throws {
        let events = Box()
        let forward = forward(events)
        forward.start()
        #expect(await eventually { events.items == [.ready] })

        runner.pid = nil
        runner.forwardStatus = 255

        #expect(await eventually { events.items.count == 2 })
        guard case .failed? = events.items.last else { Issue.record("no failure"); return }
        #expect(await eventually { pool.load == [0] })
    }

    @Test func aCloseDuringARecoveryCancelsTheReAddedForwardAndAddsNothingMore() async throws {
        let events = Box()
        let forward = forward(events)
        forward.start()
        #expect(await eventually { events.items == [.ready] })
        runner.holdNextForward = true
        runner.pid = 200

        #expect(await eventually { runner.held != nil })
        forward.stop()
        runner.release()

        #expect(await eventually { runner.operations.last == "cancel" && pool.load == [0] })
        let settled = runner.operations
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.operations == settled)
        #expect(events.items == [.ready])
    }

    private func startAndStopUnowned(_ events: Box, stopWhen ready: @escaping () -> Bool) async {
        let forward = forward(events)
        forward.start()
        _ = await eventually(ready)
        forward.stop()
    }

    @Test func aStoppedForwardNobodyHoldsStillCancelsAndReleases() async throws {
        let events = Box()

        await startAndStopUnowned(events) { events.items == [.ready] }

        #expect(await eventually { runner.operations.last == "cancel" && pool.load == [0] })
    }

    @Test func aForwardStoppedAndDroppedDuringItsAddCancelsOnceTheAddLands() async throws {
        let events = Box()
        runner.holdNextForward = true

        await startAndStopUnowned(events) { [runner] in runner.held != nil }
        runner.release()

        #expect(await eventually { runner.operations == ["forward", "cancel"] && pool.load == [0] })
    }

    @Test func anAddWhoseConnectionCheckFailsCancelsAndReleasesOnItsOwn() async throws {
        let events = Box()
        runner.pid = nil
        let forward = forward(events)

        forward.start()

        #expect(await eventually { runner.operations == ["forward", "check", "cancel"] && pool.load == [0] })
        #expect(events.items.count == 1)
        guard case .failed? = events.items.first else { Issue.record("no failure"); return }
    }

    @Test func aFailedFirstAddFailsTheForwardAndCancelsNothing() async throws {
        let events = Box()
        runner.forwardStatus = 255
        let forward = forward(events)

        forward.start()
        #expect(await eventually { events.items.count == 1 })
        guard case .failed? = events.items.first else { Issue.record("no failure"); return }

        #expect(await eventually { pool.load == [0] })
        #expect(!runner.operations.contains("cancel"))
        forward.stop()
    }
}
