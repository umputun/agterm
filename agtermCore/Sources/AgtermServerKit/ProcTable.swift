import Foundation
import agtermCore

/// ProcessTable is what agterm-server reads of the host's processes to end a pane's foreground job the way a closed
/// terminal would. A fake stands in for it in tests.
public protocol ProcessTable: Sendable {
    /// snapshot is every process, nil when the table cannot be read.
    func snapshot() -> [ProcessRecord]?
    func signal(_ signal: Int32, pids: [Int32])
}

extension ProcessTable {
    /// foregroundJob is the job holding `shell`'s terminal, nil when the table cannot be read.
    func foregroundJob(of shell: Int32) -> [ProcessRecord]? {
        snapshot().map { ProcessSweep.foregroundJob(of: shell, in: $0) }
    }

    /// isRunning is whether any process of `job` still runs; an unreadable table counts as running.
    func isRunning(_ job: [ProcessRecord]) -> Bool {
        guard let table = snapshot() else { return true }
        return !ProcessSweep.survivors(of: job, in: table).isEmpty
    }

    /// send signals the processes of `job` still running, matched on pid and start time so a recycled pid is spared.
    func send(_ signal: Int32, to job: [ProcessRecord]) {
        guard !job.isEmpty, let table = snapshot() else { return }
        let pids = ProcessSweep.survivors(of: job, in: table).map(\.pid)
        if !pids.isEmpty { self.signal(signal, pids: pids) }
    }
}

/// ProcProcessTable reads `/proc`. Linux only; elsewhere the table cannot be read.
public struct ProcProcessTable: ProcessTable {
    public init() {}

    public func snapshot() -> [ProcessRecord]? {
        #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc"),
              let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let boot = Self.bootTime(stat) else { return nil }
        let ticks = Int64(sysconf(Int32(_SC_CLK_TCK)))
        return entries.compactMap { entry in
            guard let pid = Int32(entry),
                  let line = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return nil }
            return Self.record(pid: pid, stat: line, bootTime: boot, ticksPerSecond: ticks)
        }
        #else
        return nil
        #endif
    }

    public func signal(_ signal: Int32, pids: [Int32]) {
        for pid in pids { _ = kill(pid, signal) }
    }

    /// record parses one `/proc/<pid>/stat`, counting fields after the command name's closing parenthesis since the
    /// name may hold spaces: pgrp is field 5, tpgid field 8, and the start time field 22, in clock ticks since boot.
    static func record(pid: Int32, stat: String, bootTime: Int64, ticksPerSecond: Int64) -> ProcessRecord? {
        guard ticksPerSecond > 0, let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let group = Int32(fields[2]), let foreground = Int32(fields[5]),
              let started = Int64(fields[19]) else { return nil }
        let micros = bootTime * 1_000_000 + started * 1_000_000 / ticksPerSecond
        return ProcessRecord(pid: pid, started: micros, group: group, foreground: max(foreground, 0))
    }

    /// bootTime is the `btime` line of `/proc/stat`, seconds since the epoch.
    static func bootTime(_ stat: String) -> Int64? {
        stat.split(whereSeparator: \.isNewline).lazy
            .compactMap { line -> Int64? in
                let parts = line.split(separator: " ")
                return parts.count == 2 && parts[0] == "btime" ? Int64(parts[1]) : nil
            }
            .first
    }
}

/// ProcReplay reads the process holding a pane's terminal for a replay: its argv, working directory, image and PATH,
/// all from the one pid in the foreground, the shell itself while it waits at a prompt. Linux only.
enum ProcReplay {
    static func observation(leader: Int32, shell: String?) -> RestartReplay.Observation {
        #if os(Linux)
        let group = ProcCwd.foregroundGroup(of: leader) ?? leader
        let pid = group > 0 ? group : leader
        let argv = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline").flatMap(ProcForeground.parseCmdline)
        let environment = FileManager.default.contents(atPath: "/proc/\(pid)/environ").flatMap(ProcForeground.parseCmdline)
        return RestartReplay.Observation(foreground: argv.flatMap { CommandRestore.paneForeground(argv: $0, extra: shell) },
                                         isDaemonLeader: pid == leader, workingDirectory: directory("/proc/\(pid)/cwd"),
                                         executablePath: link("/proc/\(pid)/exe"),
                                         searchPath: environment.flatMap(searchPath))
        #else
        return RestartReplay.Observation(foreground: nil, isDaemonLeader: false, workingDirectory: nil)
        #endif
    }

    /// searchPath is the PATH entry of an environment's `NAME=value` strings.
    static func searchPath(_ environment: [String]) -> String? {
        environment.first { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) }
    }

    private static func link(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func directory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard let resolved = link(path), FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return resolved
    }
}

/// ProcDaemon finds a zmx daemon's shell from `/proc` alone, so a restart sees it run without `zmx list`, which
/// waits on every other daemon. Linux only; elsewhere there is none.
enum ProcDaemon {
    /// Target is one launch's daemon: its name, this server's socket directory and zmx executable, and the launch
    /// instant in clock ticks since boot, before which none of this launch's processes started.
    struct Target: Sendable {
        let name: String
        let directory: String
        let executable: String
        let launchedAt: Int64
    }

    /// Process is what the selection reads of one process.
    struct Process {
        let pid: Int32
        let argv: () -> [String]?
        let environment: () -> [String]?
        /// started is the process's start in clock ticks since boot.
        let started: () -> Int64?
        let children: () -> [Int32]
    }

    /// now is the current instant in clock ticks since boot, the unit `/proc/<pid>/stat` records starts in.
    static func now() -> Int64 {
        #if os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/uptime", encoding: .utf8),
              let seconds = text.split(separator: " ").first.flatMap({ Double($0) }) else { return 0 }
        return Int64(seconds * Double(sysconf(Int32(_SC_CLK_TCK))))
        #else
        return 0
        #endif
    }

    /// leader is the shell pid of `target`'s daemon, nil while none runs.
    static func leader(_ target: Target) -> Int32? {
        scanned { select($0, target: target, row: $1) } ?? nil
    }

    /// leaders maps every daemon this server created in `directory` with `executable` to its shell pid, from one pass
    /// over `/proc`; nil when `/proc` cannot be read, and off Linux.
    static func leaders(directory: String, executable: String) -> [String: Int32]? {
        scanned { collect($0, directory: directory, executable: executable, row: $1) }
    }

    private static func scanned<T>(_ body: ([Process], (Int32) -> ZmxDaemonLeader.Row?) -> T) -> T? {
        #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        let pids = entries.compactMap { Int32($0) }
        let table = StatTable(pids: pids)
        let processes = pids.map { pid in
            Process(pid: pid, argv: { read("/proc/\(pid)/cmdline").flatMap(ProcForeground.parseCmdline) },
                    environment: { read("/proc/\(pid)/environ").flatMap(ProcForeground.parseCmdline) },
                    started: { stat(of: pid).flatMap(startTicks(stat:)) }, children: { table.children(of: pid) })
        }
        return body(processes, table.row(of:))
        #else
        return nil
        #endif
    }

    /// collect is `leaders` over given processes. A name two daemons share, as when an earlier one outlives its kill
    /// with its old shell, goes to the later start, then the higher pid, since starts are counted in 10 ms ticks.
    static func collect(_ processes: some Sequence<Process>, directory: String, executable: String,
                        row: (Int32) -> ZmxDaemonLeader.Row?) -> [String: Int32] {
        let zmx = Executable(executable)
        var found: [String: (started: Int64, pid: Int32, leader: Int32)] = [:]
        for process in processes {
            guard let argv = process.argv(), argv.count > 3, argv[1] == "attach", argv[2] == "--detached", zmx.matches(argv[0]),
                  process.environment()?.contains("ZMX_DIR=\(directory)") == true, let started = process.started(),
                  let leader = ZmxDaemonLeader.leader(ofDaemon: process.pid, children: process.children(), row: row) else { continue }
            if let best = found[argv[3]], (best.started, best.pid) > (started, process.pid) { continue }
            found[argv[3]] = (started, process.pid, leader)
        }
        return found.mapValues(\.leader)
    }

    /// select picks the daemon by the argv `ZmxRunner.create` starts it with, which its fork keeps, by its `ZMX_DIR`,
    /// since another state directory can run the same name, and by a start no earlier than the launch: an earlier
    /// daemon of the name can outlive its kill with its old shell.
    static func select(_ processes: some Sequence<Process>, target: Target, row: (Int32) -> ZmxDaemonLeader.Row?) -> Int32? {
        let zmx = Executable(target.executable)
        for process in processes {
            guard let argv = process.argv(), argv.count > 3, argv[1] == "attach", argv[2] == "--detached", argv[3] == target.name,
                  zmx.matches(argv[0]),
                  process.environment()?.contains("ZMX_DIR=\(target.directory)") == true,
                  let started = process.started(), started >= target.launchedAt,
                  let leader = ZmxDaemonLeader.leader(ofDaemon: process.pid, children: process.children(), row: row) else { continue }
            return leader
        }
        return nil
    }

    /// Executable matches a daemon's argv[0] against the configured zmx path, literally or through symlinks, since a
    /// restarted server's `--zmx` can name the binary its surviving daemons started from another way. A relative
    /// argv[0] would resolve against this server's directory, so only the literal match applies to it.
    struct Executable {
        let path: String
        let resolved: String

        init(_ path: String) {
            self.path = path
            resolved = (path as NSString).resolvingSymlinksInPath
        }

        func matches(_ argv0: String) -> Bool {
            argv0 == path || (argv0.hasPrefix("/") && (argv0 as NSString).resolvingSymlinksInPath == resolved)
        }
    }

    /// row parses `/proc/<pid>/stat` for the leader check, counting fields after the command name's closing
    /// parenthesis: a session leader with a controlling terminal owns it.
    static func row(pid: Int32, stat: String) -> ZmxDaemonLeader.Row? {
        let fields = fieldsAfterName(stat)
        // after the name: state, ppid, pgrp, session, tty_nr, tpgid
        guard fields.count > 5, let parent = Int32(fields[1]), let session = Int32(fields[3]), let tty = Int32(fields[4]),
              let foreground = Int32(fields[5]) else { return nil }
        return ZmxDaemonLeader.Row(parent: parent, ownsTerminal: session == pid && tty != 0, foreground: max(foreground, 0))
    }

    /// startTicks is field 22 of `/proc/<pid>/stat`, the start in clock ticks since boot.
    static func startTicks(stat: String) -> Int64? {
        let fields = fieldsAfterName(stat)
        return fields.count > 19 ? Int64(fields[19]) : nil
    }

    private static func fieldsAfterName(_ stat: String) -> [Substring] {
        guard let close = stat.lastIndex(of: ")") else { return [] }
        return stat[stat.index(after: close)...].split(separator: " ")
    }

    #if os(Linux)
    private static func read(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    private static func stat(of pid: Int32) -> String? {
        try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)
    }

    /// StatTable reads every process's stat row once, on the first daemon that matches, so children come from the
    /// parent field: `/proc/<pid>/task/<pid>/children` exists only on kernels built with CONFIG_PROC_CHILDREN.
    private final class StatTable {
        private let pids: [Int32]
        private lazy var rows: [Int32: ZmxDaemonLeader.Row] = Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            ProcDaemon.stat(of: pid).flatMap { ProcDaemon.row(pid: pid, stat: $0) }.map { (pid, $0) }
        })

        init(pids: [Int32]) { self.pids = pids }

        func children(of pid: Int32) -> [Int32] { rows.filter { $0.value.parent == pid }.map(\.key) }

        func row(of pid: Int32) -> ZmxDaemonLeader.Row? { rows[pid] }
    }
    #endif
}
