import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

struct ProcTableTests {
    @Test func aStatLineGivesGroupForegroundAndStartTimeAfterTheName() throws {
        let stat = "4242 (my (odd) prog) S 1 4240 4240 34816 4300 4194304 120 0 0 0 1 2 0 0 20 0 1 0 250 1000 200"

        let record = try #require(ProcProcessTable.record(pid: 4242, stat: stat, bootTime: 1_700_000_000, ticksPerSecond: 100))

        #expect(record == ProcessRecord(pid: 4242, started: 1_700_000_000_000_000 + 2_500_000, group: 4240, foreground: 4300))
    }

    @Test func aTruncatedStatLineIsNoRecord() {
        #expect(ProcProcessTable.record(pid: 1, stat: "1 (init) S 0 1", bootTime: 0, ticksPerSecond: 100) == nil)
    }

    @Test func aProcessWithoutATerminalHasNoForegroundGroup() throws {
        let stat = "7 (daemon) S 1 7 7 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 50 1000 200"

        #expect(try #require(ProcProcessTable.record(pid: 7, stat: stat, bootTime: 0, ticksPerSecond: 100)).foreground == 0)
    }

    @Test func bootTimeIsTheBtimeLine() {
        #expect(ProcProcessTable.bootTime("cpu  1 2 3\nbtime 1700000000\nprocesses 9\n") == 1_700_000_000)
        #expect(ProcProcessTable.bootTime("cpu  1 2 3\n") == nil)
    }

    @Test func searchPathIsThePathEntry() {
        #expect(ProcReplay.searchPath(["HOME=/home/u", "PATH=/home/u/.local/bin:/usr/bin", "TERM=x"]) == "/home/u/.local/bin:/usr/bin")
        #expect(ProcReplay.searchPath(["HOME=/home/u"]) == nil)
    }

    @Test func aSignalReachesOnlyTheJobsProcessesStillRunning() {
        let table = FakeProcessTable()
        table.shell(100, job: 300)
        let job = [ProcessRecord(pid: 300, started: 2, group: 300, foreground: 300), ProcessRecord(pid: 301, started: 9, group: 300)]

        table.send(SIGHUP, to: job)

        #expect(table.signals.map(\.pids) == [[300]])
        #expect(!table.isRunning(job))
    }

    @Test func anUnreadableTableCountsAsStillRunning() {
        let table = FakeProcessTable()
        table.table = nil

        #expect(table.isRunning([ProcessRecord(pid: 300, started: 2)]))
        #expect(table.foregroundJob(of: 100) == nil)
    }
}
