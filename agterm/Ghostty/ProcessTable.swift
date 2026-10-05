import agtermCore
import Darwin

/// ProcessTable is the live process table as `ProcessSweep` reads it.
enum ProcessTable {
    /// read returns every process visible to this user, empty when the kernel refuses.
    static func read() -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        // the table can grow between the sizing call and the read, which answers ENOMEM
        for margin in [64, 512] {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + margin)
            size = procs.count * stride
            if sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 {
                return procs.prefix(size / stride).map { proc in
                    let started = proc.kp_proc.p_starttime
                    return ProcessRecord(pid: proc.kp_proc.p_pid, parent: proc.kp_eproc.e_ppid,
                                         started: Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec),
                                         group: proc.kp_eproc.e_pgid, foreground: proc.kp_eproc.e_tpgid)
                }
            }
            if errno != ENOMEM { return [] }
        }
        return []
    }
}

/// ProcessSweeper hangs up the foreground job a killed daemon's shell leaves running, as closing a
/// terminal would have. Injected into `ZmxClient`, which has none by default: a test's fake listing
/// names pids that are real processes on the machine running it.
struct ProcessSweeper {
    var table: () -> [ProcessRecord] = ProcessTable.read
    var signal: (Int32, pid_t) -> Void = { _ = kill($1, $0) }

    /// capture returns each shell's foreground job, keyed like `shells`, omitting shells without one.
    func capture(shells: [String: pid_t]) -> [String: [ProcessRecord]] {
        let table = table()
        return shells.mapValues { ProcessSweep.foregroundJob(of: $0, in: table) }.filter { !$0.value.isEmpty }
    }

    func survivors(of job: [ProcessRecord]) -> [ProcessRecord] {
        ProcessSweep.survivors(of: job, in: table())
    }

    func send(_ signal: Int32, to job: [ProcessRecord]) {
        for record in survivors(of: job) { self.signal(signal, record.pid) }
    }
}
