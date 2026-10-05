import Testing
@testable import agtermCore

struct ProcessSweepTests {
    private let shell = ProcessRecord(pid: 100, started: 10, group: 100, foreground: 300)
    private var table: [ProcessRecord] {
        [
            shell,
            ProcessRecord(pid: 300, started: 11, group: 300, foreground: 300),
            ProcessRecord(pid: 301, started: 12, group: 300, foreground: 300),
            ProcessRecord(pid: 400, started: 13, group: 400, foreground: 300),
            ProcessRecord(pid: 500, started: 14, group: 500, foreground: 0),
        ]
    }

    @Test func foregroundJobIsTheTerminalsForegroundGroupOnly() {
        let job = ProcessSweep.foregroundJob(of: 100, in: table)
        #expect(Set(job.map(\.pid)) == [300, 301])
    }

    @Test func aShellAtItsPromptHasNoForegroundJob() {
        let idle = [ProcessRecord(pid: 100, started: 10, group: 100, foreground: 100),
                    ProcessRecord(pid: 400, started: 13, group: 400, foreground: 100)]
        #expect(ProcessSweep.foregroundJob(of: 100, in: idle).isEmpty)
    }

    @Test func anUnknownShellOrOneWithoutATerminalHasNoForegroundJob() {
        #expect(ProcessSweep.foregroundJob(of: 999, in: table).isEmpty)
        #expect(ProcessSweep.foregroundJob(of: 500, in: table).isEmpty)
    }

    @Test func survivorsMatchPidAndStartTime() {
        let snapshot = ProcessSweep.foregroundJob(of: 100, in: table)
        let later = [ProcessRecord(pid: 300, started: 11), ProcessRecord(pid: 301, started: 999)]
        #expect(ProcessSweep.survivors(of: snapshot, in: later).map(\.pid) == [300])
    }

    @Test func survivorsNeverNameLaunchd() {
        let snapshot = [ProcessRecord(pid: 1, started: 1), ProcessRecord(pid: 0, started: 0)]
        #expect(ProcessSweep.survivors(of: snapshot, in: snapshot).isEmpty)
    }
}
