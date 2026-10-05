/// ProcessRecord is one row of the process table, identified by pid plus start time so a recycled pid
/// is not mistaken for the process that held it.
public struct ProcessRecord: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let parent: Int32
    /// started is the start time in microseconds since the epoch.
    public let started: Int64
    public let group: Int32
    /// foreground is the foreground process group of the process's terminal, 0 without one.
    public let foreground: Int32

    public init(pid: Int32, parent: Int32, started: Int64, group: Int32 = 0, foreground: Int32 = 0) {
        self.pid = pid
        self.parent = parent
        self.started = started
        self.group = group
        self.foreground = foreground
    }
}

/// ProcessSweep selects the one thing a killed pane shell leaves running that a closed terminal would
/// have ended: its foreground job. `zmx kill` signals the shell's own process group, and a pane's
/// creation command runs in a group of its own. Background and disowned jobs are never selected.
public enum ProcessSweep {
    /// foregroundJob returns the members of the terminal's foreground group when `shell` is not in it.
    public static func foregroundJob(of shell: Int32, in table: [ProcessRecord]) -> [ProcessRecord] {
        guard let leader = table.first(where: { $0.pid == shell }), leader.foreground > 1,
              leader.foreground != leader.group else { return [] }
        return table.filter { $0.group == leader.foreground && $0.pid != shell }
    }

    /// survivors returns the snapshot entries still running in `table`, matched on pid and start time.
    public static func survivors(of snapshot: [ProcessRecord], in table: [ProcessRecord]) -> [ProcessRecord] {
        let running = Set(table.map { Identity(pid: $0.pid, started: $0.started) })
        return snapshot.filter { $0.pid > 1 && running.contains(Identity(pid: $0.pid, started: $0.started)) }
    }

    private struct Identity: Hashable {
        let pid: Int32
        let started: Int64
    }
}
