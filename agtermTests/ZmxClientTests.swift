import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ZmxClientTests: XCTestCase {
    func testListSessionsInvokesOnlyListInTheInstanceNamespace() throws {
        var invocations: [ZmxClient.Invocation] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", timeout: 1.5) {
            invocations.append($0)
            return """
            name=agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tpid=1\tclients=0\tcreated=1
            name=agterm-busy\terr=Timeout\tstatus=unreachable
            """
        }

        let records = try XCTUnwrap(client.listSessions())

        XCTAssertEqual(invocations.map(\.arguments), [["list"]], "the read must mutate nothing")
        XCTAssertEqual(invocations.first?.environment["ZMX_DIR"], "/tmp/zmx-dir")
        XCTAssertNil(invocations.first?.environment["ZMX_SESSION"],
                     "the app must not inherit a pane's own session into its listing")
        XCTAssertEqual(records.map(\.name), ["agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "agterm-busy"])
        XCTAssertEqual(records.first?.clients, 0)
        XCTAssertNil(records.last?.clients, "an err= row keeps its unreadable client count")
    }

    func testListSessionsReturnsEmptyForAnEmptyNamespaceAndNilOnFailure() {
        let empty = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in "" }
        XCTAssertEqual(empty.listSessions(), [], "no daemons is an answer, not a failure")

        let broken = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            throw ZmxClient.CommandError.timedOut
        }
        XCTAssertNil(broken.listSessions(), "a failed invocation must not read as an empty namespace")

        let garbled = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            "pid=10\tclients=0\n"
        }
        XCTAssertNil(garbled.listSessions(), "an unparseable line must not read as an empty namespace")
    }

    func testKillObservedOrphanNeverForcesAndSeparatesAStaleSocketFromAKill() {
        var invocations: [[String]] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { invocation in
            invocations.append(invocation.arguments)
            return invocation.arguments.contains("agterm-gone")
                ? "cleaned up stale session agterm-gone\n"
                : "killed session agterm-live\n"
        }

        let outcomes = client.killObservedOrphan(names: ["agterm-live", "agterm-gone"])

        XCTAssertEqual(outcomes["agterm-live"], .killed)
        XCTAssertEqual(outcomes["agterm-gone"], .staleSocket,
                       "an unlinked socket may leave the daemon running, so it is not a kill")
        XCTAssertEqual(Set(invocations), [["kill", "agterm-live"], ["kill", "agterm-gone"]])
        XCTAssertFalse(invocations.contains { $0.contains("--force") },
                       "--force would unlink a live daemon's socket and still exit zero")
    }

    func testKillOutcomeTrustsOnlyAnExactConfirmationLine() {
        let name = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        XCTAssertEqual(ZmxClient.outcome(of: "killed session \(name)\n", name: name), .killed)
        XCTAssertEqual(ZmxClient.outcome(of: "cleaned up stale session \(name)\n", name: name), .staleSocket)

        // zmx exits zero here too, after merely reporting on stderr it could not reach the daemon
        let unresponsive = "failed to kill session=\(name): SessionUnresponsive\n"
        XCTAssertEqual(ZmxClient.outcome(of: unresponsive, name: name),
                       .failed("failed to kill session=\(name): SessionUnresponsive"))

        // a broken pipe after the kill was sent returns with nothing printed
        XCTAssertEqual(ZmxClient.outcome(of: "", name: name), .failed("no output"))

        XCTAssertEqual(ZmxClient.outcome(of: "not killed session \(name)\n", name: name),
                       .failed("not killed session \(name)"),
                       "a line merely containing the confirmation must not count as one")
        XCTAssertEqual(ZmxClient.outcome(of: "killed session agterm-other\n", name: name),
                       .failed("killed session agterm-other"),
                       "another daemon's confirmation is not this one's")
    }

    func testKillInvocationsMergeStderrAndListDoesNot() {
        var invocations: [ZmxClient.Invocation] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") {
            invocations.append($0)
            return ""
        }

        _ = client.listSessions()
        _ = client.killObservedOrphan(names: ["agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        _ = client.killConfirmed(name: "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        client.kill(paneIdentities: [UUID()])

        let byCommand = Dictionary(grouping: invocations, by: { $0.arguments.first ?? "" })
        XCTAssertEqual(byCommand["list"]?.map(\.mergesStderr), [false])
        XCTAssertEqual(byCommand["kill"]?.map(\.mergesStderr), [true, true, true])
    }

    func testScreenReadsTheDaemonsTerminalAndAFailureIsNeverABlankScreen() throws {
        var invocations: [[String]] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") {
            invocations.append($0.arguments)
            return "7 101 33 2 9 0\n> draft\n"
        }

        let active = try XCTUnwrap(client.screen(name: "agterm-a", all: false))
        _ = client.screen(name: "agterm-a", all: true)

        XCTAssertEqual(invocations, [["screen", "agterm-a"], ["screen", "agterm-a", "--all"]])
        XCTAssertEqual(active.columns, 101)
        XCTAssertEqual(active.cursorColumn, 2)
        XCTAssertEqual(active.text, "> draft\n")

        let old = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            throw ZmxClient.CommandError.failed(1, "error: screen failed for \"agterm-a\": Timeout")
        }
        XCTAssertNil(old.screen(name: "agterm-a", all: false), "a zmx without the query must not read as blank")
        let garbled = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in "usage: zmx" }
        XCTAssertNil(garbled.screen(name: "agterm-a", all: false))
    }

    func testTypeSendsTheExactBytesOnStdinAndReportsARejection() {
        var invocations: [ZmxClient.Invocation] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") {
            invocations.append($0)
            return ""
        }

        XCTAssertTrue(client.type(name: "agterm-a", bytes: [0x0D]))

        XCTAssertEqual(invocations.map(\.arguments), [["type", "agterm-a"]])
        XCTAssertEqual(invocations.first?.input, Data([0x0D]), "a lone Return must reach zmx, not be trimmed away")

        let full = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            throw ZmxClient.CommandError.failed(1, "error: type rejected")
        }
        XCTAssertFalse(full.type(name: "agterm-a", bytes: [0x61]))
    }

    func testRunFeedsInputToTheChildsStdinAndClosesIt() throws {
        let invocation = ZmxClient.Invocation(executablePath: "/bin/cat", arguments: [], environment: [:],
                                              timeout: 5, mergesStderr: false, input: Data("typed\r".utf8))

        XCTAssertEqual(try ZmxClient.run(invocation), "typed\r")
    }

    func testRunAppendsStderrOnlyWhenTheInvocationAsksForIt() throws {
        func invocation(mergesStderr: Bool) -> ZmxClient.Invocation {
            ZmxClient.Invocation(executablePath: "/bin/sh", arguments: ["-c", "echo notice >&2; echo row"],
                                 environment: [:], timeout: 5, mergesStderr: mergesStderr)
        }

        XCTAssertEqual(try ZmxClient.run(invocation(mergesStderr: false)), "row\n")
        XCTAssertEqual(try ZmxClient.run(invocation(mergesStderr: true)), "row\nnotice\n")
    }

    func testRunDrainsOutputLargerThanThePipeBufferBeforeTheProcessExits() throws {
        let invocation = ZmxClient.Invocation(
            executablePath: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x; head -c 200000 /dev/zero | tr '\\0' y >&2"],
            environment: [:], timeout: 5, mergesStderr: true)
        let started = Date()

        let output = try ZmxClient.run(invocation)

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(output.count, 400_000)
        XCTAssertEqual(output.prefix(1), "x")
        XCTAssertEqual(output.suffix(1), "y")
    }

    func testRunGivesUpOnAWriteEndHeldPastTheChildsExit() {
        let invocation = ZmxClient.Invocation(
            executablePath: "/bin/sh", arguments: ["-c", "sleep 30 & echo row"],
            environment: [:], timeout: 5, mergesStderr: false)
        let started = Date()

        XCTAssertThrowsError(try ZmxClient.run(invocation)) { error in
            guard case ZmxClient.CommandError.timedOut = error else { return XCTFail("\(error)") }
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), ZmxClient.terminationGrace + 1)
    }

    func testRunThrowsForAnExecutableThatCannotLaunch() {
        let invocation = ZmxClient.Invocation(executablePath: "/nonexistent/zmx-\(UUID().uuidString)", arguments: ["list"],
                                              environment: [:], timeout: 5, mergesStderr: false)

        XCTAssertThrowsError(try ZmxClient.run(invocation)) { error in
            if case ZmxClient.CommandError.timedOut = error { XCTFail("a failed launch must not wait out a deadline") }
        }
    }

    func testLiveReapListsThenKillsOnlyUnclaimedZeroClientNames() {
        let known = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let orphan = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        var invocations: [ZmxClient.Invocation] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", timeout: 1.5) {
            invocations.append($0)
            if $0.arguments == ["list"] {
                return """
                name=\(ZmxSupport.daemonName(for: known))\tpid=1\tclients=0\tcreated=1
                name=\(orphan)\tpid=2\tclients=0\tcreated=1
                name=agterm-attached\tpid=3\tclients=1\tcreated=1
                """
            }
            return ""
        }

        XCTAssertTrue(client.reap(
            knownPaneIdentities: [known],
            launchDecision: RestoreMode.live.launchDecision(liveUnavailableReason: nil)).killedAll)
        XCTAssertEqual(invocations.map(\.arguments), [["list"], ["kill", orphan, "--force"]])
        XCTAssertEqual(invocations.map(\.timeout), [1.5, 1.5])
        XCTAssertEqual(invocations[0].environment["ZMX_DIR"], "/tmp/zmx-dir")
        XCTAssertNil(invocations[0].environment["ZMX_SESSION"])
    }

    func testIncompleteLiveInventorySkipsEveryProcessInvocation() {
        var calls = 0
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            calls += 1
            return ""
        }

        XCTAssertTrue(client.reap(
            knownPaneIdentities: nil,
            launchDecision: RestoreMode.live.launchDecision(liveUnavailableReason: nil)).killedAll)
        XCTAssertEqual(calls, 0)
    }

    func testRequestedLiveFallbackPreservesClaimedDaemons() {
        let known = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var invocations: [[String]] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") {
            invocations.append($0.arguments)
            return "name=\(ZmxSupport.daemonName(for: known))\tpid=1\tclients=0\tcreated=1"
        }

        let fallback = RestoreMode.live.launchDecision(liveUnavailableReason: "login shell is not zsh")
        XCTAssertEqual(fallback.active, .none)
        XCTAssertTrue(client.reap(knownPaneIdentities: [known], launchDecision: fallback).killedAll)
        XCTAssertEqual(invocations, [["list"]])
    }

    func testReapReportsEveryReadableDaemonAsRunning() {
        let known = UUID()
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            """
            name=\(ZmxSupport.daemonName(for: known))\tpid=1\tclients=0\tcreated=1
            name=agterm-attached\tpid=3\tclients=1\tcreated=1
            name=agterm-stale\terr=Timeout\tstatus=unreachable
            """
        }

        let outcome = client.reap(knownPaneIdentities: [known],
                                  launchDecision: RestoreMode.live.launchDecision(liveUnavailableReason: nil))

        XCTAssertTrue(outcome.killedAll)
        XCTAssertEqual(outcome.runningNames, [ZmxSupport.daemonName(for: known), "agterm-attached"],
                       "an err= row is unreadable, so its pane must pace like a missing daemon")
    }

    func testReapReportsNoRunningNamesWhenTheListIsSkippedOrFails() {
        let failing = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            throw ZmxClient.CommandError.timedOut
        }
        let live = RestoreMode.live.launchDecision(liveUnavailableReason: nil)

        let failed = failing.reap(knownPaneIdentities: [UUID()], launchDecision: live)
        let skipped = failing.reap(knownPaneIdentities: nil, launchDecision: live)

        XCTAssertEqual(failed, ZmxClient.ReapOutcome(runningNames: nil, killedAll: false))
        XCTAssertEqual(skipped, ZmxClient.ReapOutcome(runningNames: nil, killedAll: true))
    }

    func testAFailedOrphanKillKeepsTheRunningNames() {
        let known = UUID()
        let orphan = ZmxSupport.daemonName(for: UUID())
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { invocation in
            guard invocation.arguments == ["list"] else { throw ZmxClient.CommandError.timedOut }
            return """
            name=\(ZmxSupport.daemonName(for: known))\tpid=1\tclients=0\tcreated=1
            name=\(orphan)\tpid=2\tclients=0\tcreated=1
            """
        }

        let outcome = client.reap(knownPaneIdentities: [known],
                                  launchDecision: RestoreMode.live.launchDecision(liveUnavailableReason: nil))

        XCTAssertFalse(outcome.killedAll)
        XCTAssertEqual(outcome.runningNames, [ZmxSupport.daemonName(for: known), orphan],
                       "a good list stands even when the orphan kill fails")
    }

    func testSemanticKillUsesFullPaneDaemonNames() {
        let pane = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        var arguments: [String] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") {
            arguments = $0.arguments
            return ""
        }

        XCTAssertTrue(client.kill(paneIdentities: [pane]))
        XCTAssertEqual(arguments, ["kill", "agterm-abcdef0123456789abcdef0123456789", "--force"])
    }

    func testLeaderRefreshUsesOneFullListingAndParsesOnlyAppSessions() {
        var invocations: [ZmxClient.Invocation] = []
        let ours = ZmxSupport.daemonName(for: UUID())
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") {
            invocations.append($0)
            return """
            name=\(ours)\tpid=10\tclients=1\tcreated=1
            name=other\tpid=11\tclients=0\tcreated=1
            name=agterm-notes\tpid=12\tclients=0\tcreated=1
            """
        }

        XCTAssertEqual(client.sessionLeaderPIDs(), [ours: 10])
        XCTAssertEqual(invocations.map(\.arguments), [["list"]])
    }

    func testLeaderRefreshCanOverrideOnlyItsInvocationTimeout() {
        var invocations: [ZmxClient.Invocation] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", timeout: 3) {
            invocations.append($0)
            return ""
        }

        XCTAssertEqual(client.sessionLeaderPIDs(timeout: 0.1), [:])
        XCTAssertEqual(client.listSessions(), [])
        XCTAssertEqual(invocations.map(\.timeout), [0.1, 3])
    }

    func testLeaderRefreshWallClockIsBoundedByTimeoutPlusTerminationGrace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-zmx-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("long-running")
        try """
        #!/bin/sh
        while :; do :; done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ZmxClient(executablePath: executable.path, socketDirectory: root.path)
        let started = Date()

        XCTAssertNil(client.sessionLeaderPIDs(timeout: 0.1))

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(ZmxClient.captureWallClockLimit,
                       ZmxClient.captureInvocationTimeout + ZmxClient.terminationGrace)
        XCTAssertGreaterThanOrEqual(elapsed, 0.09)
        XCTAssertLessThan(elapsed, ZmxClient.captureWallClockLimit + 0.1)
    }
}
