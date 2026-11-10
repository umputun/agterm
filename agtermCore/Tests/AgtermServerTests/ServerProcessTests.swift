import Foundation
import Testing
@testable import AgtermServerKit

struct ServerProcessTests {
    #if os(Linux)
    private static var server: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/agterm-server").path
    }

    @Test func cleanExecClosesInheritedDescriptors() throws {
        let script = "exec 7</dev/null 9</dev/null; exec \"$0\" \(CleanExec.argument) /bin/ls /proc/self/fd"
        let output = try ServerProcess.run(["/bin/sh", "-c", script, Self.server], environment: [:], timeout: 10)

        #expect(output.status == 0)
        #expect(output.stdout.split(separator: "\n").sorted() == ["0", "1", "2", "3"])
    }

    @Test func cleanExecReportsAProgramItCannotRun() throws {
        let output = try ServerProcess.run([Self.server, CleanExec.argument, "/nonexistent/program"], environment: [:], timeout: 10)

        #expect(output.status == 127)
        #expect(output.stderr.contains("/nonexistent/program"))
    }
    #endif

    @Test func outputAndStatusAreCollected() throws {
        let output = try ServerProcess.run(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"], environment: [:], timeout: 5)

        #expect(output == ServerProcess.Output(status: 3, stdout: "out\n", stderr: "err\n"))
    }

    @Test func inputReachesTheChild() throws {
        let output = try ServerProcess.run(["/bin/cat"], environment: [:], input: Data("typed".utf8), timeout: 5)

        #expect(output.stdout == "typed")
    }

    @Test func aChildPastItsTimeoutIsEnded() {
        let began = Date()

        #expect(throws: ServerProcess.Failure.timedOut(["/bin/sleep", "30"])) {
            try ServerProcess.run(["/bin/sleep", "30"], environment: [:], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(began) < 3)
    }

    @Test func inputTheChildNeverReadsIsBoundedByTheTimeout() {
        let finished = Self.within(5) {
            _ = try? ServerProcess.run(["/bin/sleep", "30"], environment: [:], input: Data(count: 1 << 20), timeout: 0.3)
            return true
        }

        #expect(finished == true)
    }

    @Test func outputWrittenBeforeTheChildReadsItsInputIsDrained() throws {
        let output = Self.within(5) {
            try? ServerProcess.run(["/bin/sh", "-c", "head -c 200000 /dev/zero; cat >/dev/null; echo done >&2"],
                                   environment: [:], input: Data(count: 200_000), timeout: 4)
        } ?? nil

        #expect(output?.stdout.utf8.count == 200_000)
        #expect(output?.stderr == "done\n")
    }

    @Test func aTimedOutChildReleasesThePipeItsSurvivorHolds() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("agts-pipe-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let survivor = "trap '' PIPE; (sleep 0.5; while echo x; do sleep 0.05; done; touch '\(marker)') & sleep 30"

        #expect(throws: ServerProcess.Failure.self) {
            try ServerProcess.run(["/bin/sh", "-c", survivor], environment: [:], timeout: 0.3)
        }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(FileManager.default.fileExists(atPath: marker))
    }

    @Test func aTimedOutChildStopsFeedingInputItsSurvivorHolds() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("agts-stdin-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let input = Data(count: 4 << 20)

        #expect(throws: ServerProcess.Failure.self) {
            try ServerProcess.run(["/bin/sh", "-c", "exec 3<&0; (sleep 1; wc -c <&3 >'\(marker).tmp'; mv '\(marker).tmp' '\(marker)') & sleep 30"],
                                  environment: [:], input: input, timeout: 0.3)
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let read = try #require(try? String(contentsOfFile: marker, encoding: .utf8))
        #expect((Int(read.trimmingCharacters(in: .whitespacesAndNewlines)) ?? input.count) < input.count)
    }

    // regression: on Linux a daemon inherited every descriptor not marked close-on-exec and held it for life
    @Test func aChildGetsNoDescriptorBeyondItsStandardThree() throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        defer { fds.forEach { close($0) } }

        let output = try ServerProcess.run(["/bin/sh", "-c", "test -e /dev/fd/\(fds[1]) && echo open || echo closed"],
                                           environment: [:], timeout: 5)

        #expect(output.stdout == "closed\n")
    }

    @Test func aBackgroundProcessHoldingThePipeDoesNotHoldTheReply() throws {
        let began = Date()

        let output = try ServerProcess.run(["/bin/sh", "-c", "sleep 5 & echo started"], environment: [:], timeout: 5)

        #expect(output.stdout == "started\n")
        #expect(Date().timeIntervalSince(began) < 2)
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    private static func within<T>(_ seconds: TimeInterval, _ body: @escaping @Sendable () -> T) -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Thread {
            box.value = body()
            done.signal()
        }.start()
        return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
    }
}
