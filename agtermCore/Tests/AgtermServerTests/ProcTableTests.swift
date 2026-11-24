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

    private let target = ProcDaemon.Target(name: "agterm-a", directory: "/run/zmx", executable: "/opt/zmx", launchedAt: 500)

    private func daemon(_ pid: Int32, executable: String = "/opt/zmx", directory: String = "/run/zmx", started: Int64 = 600,
                        child: Int32) -> ProcDaemon.Process {
        ProcDaemon.Process(pid: pid, argv: { [executable, "attach", "--detached", "agterm-a", "/bin/zsh"] },
                           environment: { ["HOME=/root", "ZMX_DIR=\(directory)"] }, started: { started }, children: { [child] })
    }

    private func shellRow(of daemons: [Int32: Int32]) -> (Int32) -> ZmxDaemonLeader.Row? {
        { child in daemons[child].map { ZmxDaemonLeader.Row(parent: $0, ownsTerminal: true, foreground: child) } }
    }

    @Test func aDaemonStartedBeforeTheLaunchStillRunningItsShellDoesNotHideTheNewOne() {
        let processes = [daemon(10, started: 400, child: 100), daemon(20, child: 200)]

        #expect(ProcDaemon.select(processes, target: target, row: shellRow(of: [100: 10, 200: 20])) == 200)
    }

    @Test func theSameNameUnderAnotherSocketDirectoryIsNotThisDaemon() {
        #expect(ProcDaemon.select([daemon(10, directory: "/run/other", child: 100)], target: target, row: shellRow(of: [100: 10])) == nil)
    }

    @Test func aDaemonOfAnotherZmxExecutableIsNotThisDaemon() {
        #expect(ProcDaemon.select([daemon(10, executable: "/usr/bin/zmx", child: 100)], target: target, row: shellRow(of: [100: 10])) == nil)
    }

    @Test func aRenamedZmxIsFoundByItsConfiguredPath() {
        let renamed = ProcDaemon.Target(name: "agterm-a", directory: "/run/zmx", executable: "/opt/bin/zmx-0.8", launchedAt: 500)

        #expect(ProcDaemon.select([daemon(10, executable: "/opt/bin/zmx-0.8", child: 100)], target: renamed,
                                  row: shellRow(of: [100: 10])) == 100)
    }

    @Test func theTransientCreatorWithoutAPtyShellIsNotTheDaemon() {
        let creator = ProcDaemon.Process(pid: 5, argv: { ["/opt/zmx", "attach", "--detached", "agterm-a"] },
                                         environment: { ["ZMX_DIR=/run/zmx"] }, started: { 550 }, children: { [10] })
        let rows: (Int32) -> ZmxDaemonLeader.Row? = { pid in
            pid == 10 ? ZmxDaemonLeader.Row(parent: 5, ownsTerminal: false, foreground: 0)
                : pid == 100 ? ZmxDaemonLeader.Row(parent: 10, ownsTerminal: true, foreground: 100) : nil
        }

        #expect(ProcDaemon.select([creator, daemon(10, child: 100)], target: target, row: rows) == 100)
    }

    private func named(_ pid: Int32, _ name: String, directory: String = "/run/zmx", started: Int64 = 600,
                       child: Int32) -> ProcDaemon.Process {
        ProcDaemon.Process(pid: pid, argv: { ["/opt/zmx", "attach", "--detached", name, "/bin/zsh"] },
                           environment: { ["ZMX_DIR=\(directory)"] }, started: { started }, children: { [child] })
    }

    @Test func leadersMapEveryDaemonOfThisDirectoryAndExecutableScratchesIncluded() {
        let scratch = ZmxSupport.scratchDaemonName(for: UUID())
        let processes = [named(10, "agterm-a", child: 100), named(20, scratch, child: 200),
                         named(30, "agterm-b", directory: "/run/other", child: 300), daemon(40, executable: "/usr/bin/zmx", child: 400)]

        let leaders = ProcDaemon.collect(processes, directory: "/run/zmx", executable: "/opt/zmx",
                                         row: shellRow(of: [100: 10, 200: 20, 300: 30, 400: 40]))

        #expect(leaders == ["agterm-a": 100, scratch: 200])
    }

    @Test func leadersGiveASharedNameToTheLaterStartThenTheHigherPid() {
        let processes = [named(10, "agterm-a", started: 700, child: 100), named(20, "agterm-a", started: 600, child: 200),
                         named(30, "agterm-b", started: 600, child: 300), named(40, "agterm-b", started: 600, child: 400)]

        let leaders = ProcDaemon.collect(processes, directory: "/run/zmx", executable: "/opt/zmx",
                                         row: shellRow(of: [100: 10, 200: 20, 300: 30, 400: 40]))

        #expect(leaders == ["agterm-a": 100, "agterm-b": 400])
    }

    @Test func leadersSkipTheTransientCreatorSoItNeverShadowsItsDaemon() {
        let creator = ProcDaemon.Process(pid: 5, argv: { ["/opt/zmx", "attach", "--detached", "agterm-a"] },
                                         environment: { ["ZMX_DIR=/run/zmx"] }, started: { 900 }, children: { [10] })
        let rows: (Int32) -> ZmxDaemonLeader.Row? = { pid in
            pid == 10 ? ZmxDaemonLeader.Row(parent: 5, ownsTerminal: false, foreground: 0)
                : pid == 100 ? ZmxDaemonLeader.Row(parent: 10, ownsTerminal: true, foreground: 100) : nil
        }

        #expect(ProcDaemon.collect([creator, named(10, "agterm-a", child: 100)], directory: "/run/zmx", executable: "/opt/zmx",
                                   row: rows) == ["agterm-a": 100])
    }

    @Test func aStatLineGivesTheParentWhetherItLeadsASessionWithATerminalAndItsStart() throws {
        let line = "100 (zsh -l) S 10 100 100 34816 120 4194560 1 0 0 0 0 0 0 0 20 0 1 0 98765 1000 10"
        let row = try #require(ProcDaemon.row(pid: 100, stat: line))

        #expect(row == ZmxDaemonLeader.Row(parent: 10, ownsTerminal: true, foreground: 120))
        #expect(ProcDaemon.startTicks(stat: line) == 98765)
        #expect(ProcDaemon.row(pid: 100, stat: "100 (zsh) S 10 100 100 0 -1 0")?.ownsTerminal == false)
        #expect(ProcDaemon.row(pid: 100, stat: "100 (zsh) S 10 100 99 34816 120 0")?.ownsTerminal == false)
    }
}
