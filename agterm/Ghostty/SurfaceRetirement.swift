import AppKit
import GhosttyKit
import os

/// Frees retired surfaces (`GhosttySurfaceView.retireSurface`) once their renderer and io threads have exited,
/// one per main-queue turn, so `ghostty_surface_free` no longer waits on them. A surface whose child never
/// exits stays here, as its free would otherwise have blocked the main thread for good.
@MainActor
final class SurfaceRetirement {
    static let shared = SurfaceRetirement()

    private struct Entry {
        let view: GhosttySurfaceView
        let surface: ghostty_surface_t
        let since: ContinuousClock.Instant
        var warned = false
    }

    private var entries: [Entry] = []
    private var scheduled = false
    private let logger = Logger(subsystem: "com.umputun.agterm", category: "surface-retirement")

    var pendingCount: Int { entries.count }

    func retire(_ view: GhosttySurfaceView, surface: ghostty_surface_t) {
        entries.append(Entry(view: view, surface: surface, since: .now))
        schedule()
    }

    /// drainForQuit frees every retired surface whose threads exit within `budget`. Each io thread hangs up its
    /// child as it exits, and no sweep runs once the app exits, so quit waits here for that hangup; the bound
    /// keeps a child that ignores it from holding quit.
    func drainForQuit(budget: Duration = .seconds(1)) {
        let deadline = ContinuousClock.now + budget
        while true {
            freeExited()
            guard !entries.isEmpty, ContinuousClock.now < deadline else { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func freeExited() {
        var index = entries.startIndex
        while index < entries.endIndex {
            guard ghostty_surface_try_free(entries[index].surface) else {
                index += 1
                continue
            }
            entries.remove(at: index).view.finishDestroy()
        }
    }

    private func schedule() {
        guard !scheduled, !entries.isEmpty else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [self] in
            scheduled = false
            sweep()
        }
    }

    private func sweep() {
        if let index = entries.firstIndex(where: { ghostty_surface_try_free($0.surface) }) {
            let entry = entries.remove(at: index)
            let waited = ContinuousClock.now - entry.since
            logger.notice("freed retired surface after \(waited.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            entry.view.finishDestroy()
        }
        for index in entries.indices where !entries[index].warned && ContinuousClock.now - entries[index].since > .seconds(30) {
            entries[index].warned = true
            logger.error("retired surface still waiting for its threads after 30 s")
        }
        schedule()
    }
}
