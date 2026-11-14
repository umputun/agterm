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
