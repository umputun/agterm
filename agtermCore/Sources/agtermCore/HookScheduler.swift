import Foundation

/// Starts one hook child. Throwing means no child started and neither callback will ever run. A returned
/// pid promises exactly one `onExit`, delivered after input cleanup and after any `onDeliveryFailure`,
/// and neither callback runs inline from `launch`.
@MainActor
public protocol HookLauncher: AnyObject {
    func launch(entry: HookEntry, event: ControlEvent,
                onDeliveryFailure: @escaping @MainActor @Sendable (String) -> Void,
                onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws -> Int32
}

/// Runs `hooks.conf` entries against control events: one child per hook at a time, an ordered bounded
/// queue behind it, and only process exit releasing the slot. Host-free; the app supplies the launcher.
@MainActor
public final class HookScheduler {
    public static let pendingCapacity = 256

    /// The sole banner source: called once per hook failure until that hook succeeds or the file reloads.
    public var onFailure: ((HookEntry, String) -> Void)?

    private struct Running {
        let pid: Int32
        let startedAt: Date
        let run: UInt64
        var deliveryFailed = false
    }

    private final class Record {
        var entry: HookEntry
        var running: Running?
        var pending: [ControlEvent] = []
        var dropped: UInt64 = 0
        var lastFailure: String?
        var bannerShown = false
        var retired = false

        init(entry: HookEntry) { self.entry = entry }
    }

    private let launcher: HookLauncher
    private let now: () -> Date
    private var records: [HookIdentity: Record] = [:]
    private var order: [HookIdentity] = []
    private var nextRun: UInt64 = 1

    public init(launcher: HookLauncher, now: @escaping () -> Date = Date.init) {
        self.launcher = launcher
        self.now = now
    }

    /// Replaces the definitions. An unchanged identity keeps its child, queue and counters and takes the
    /// new line; a removed one drops its queue, accepts nothing and stays until its child exits; a re-add
    /// before that exit reattaches. Every banner is re-armed.
    public func apply(_ hooks: Hooks) {
        let live = Set(hooks.entries.map(\.identity))
        for (identity, record) in records where !live.contains(identity) {
            record.retired = true
            record.pending = []
            if record.running == nil { records[identity] = nil }
        }
        for entry in hooks.entries {
            if let record = records[entry.identity] {
                record.entry = entry
                record.retired = false
            } else {
                records[entry.identity] = Record(entry: entry)
            }
        }
        for record in records.values { record.bannerShown = false }
        order = hooks.entries.map(\.identity)
    }

    /// Fans one ring event out to every live hook of its kind.
    public func dispatch(_ event: ControlEvent) {
        for identity in order {
            guard let record = records[identity], !record.retired, record.entry.kind == event.kind else { continue }
            if record.running == nil {
                start(record, event: event)
            } else {
                record.pending.append(event)
                if record.pending.count > HookScheduler.pendingCapacity {
                    record.pending.removeFirst()
                    record.dropped += 1
                }
            }
        }
    }

    /// The live hooks in file order, then any removed hook whose child is still running, for `hooks.list`.
    public var status: [ControlHookEntry] {
        let live = order.compactMap { records[$0] }.map { row($0) }
        let retired = records.values.filter { $0.retired && $0.running != nil }
            .sorted { ($0.entry.kind.rawValue, $0.entry.command) < ($1.entry.kind.rawValue, $1.entry.command) }
        return live + retired.map { row($0) }
    }

    private func row(_ record: Record) -> ControlHookEntry {
        ControlHookEntry(
            kind: record.entry.kind.rawValue, command: record.entry.command, line: record.entry.line,
            runningPid: record.running?.pid,
            elapsedSeconds: record.running.map { now().timeIntervalSince($0.startedAt) },
            pending: record.pending.count, dropped: record.dropped, lastFailure: record.lastFailure,
            retired: record.retired ? true : nil)
    }

    private func start(_ record: Record, event: ControlEvent) {
        var next: ControlEvent? = event
        while let current = next {
            next = nil
            let identity = record.entry.identity
            let run = nextRun
            nextRun += 1
            do {
                let pid = try launcher.launch(
                    entry: record.entry, event: current,
                    onDeliveryFailure: { [weak self] message in self?.deliveryFailed(identity, run: run, message) },
                    onExit: { [weak self] status in self?.exited(identity, run: run, status: status) })
                record.running = Running(pid: pid, startedAt: now(), run: run)
            } catch {
                fail(record, "spawn failed: \(error.localizedDescription)")
                if !record.pending.isEmpty { next = record.pending.removeFirst() }
            }
        }
    }

    private func deliveryFailed(_ identity: HookIdentity, run: UInt64, _ message: String) {
        guard let record = records[identity], record.running?.run == run else { return }
        record.running?.deliveryFailed = true
        fail(record, "delivery failed: \(message)")
    }

    private func exited(_ identity: HookIdentity, run: UInt64, status: Int32) {
        guard let record = records[identity], let running = record.running, running.run == run else { return }
        record.running = nil
        if status != 0 {
            fail(record, "exit \(status)")
        } else if !running.deliveryFailed {
            record.lastFailure = nil
            record.bannerShown = false
        }
        if record.retired {
            records[identity] = nil
            return
        }
        if !record.pending.isEmpty { start(record, event: record.pending.removeFirst()) }
    }

    private func fail(_ record: Record, _ message: String) {
        record.lastFailure = message
        guard !record.bannerShown else { return }
        record.bannerShown = true
        onFailure?(record.entry, message)
    }
}
