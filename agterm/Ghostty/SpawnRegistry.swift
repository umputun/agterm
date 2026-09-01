import agtermCore
import Foundation

/// Turns a `SpawnPacer` grant back into a spawn. The pacer is host-free and knows only pane keys, so the
/// app owns one registry that maps a granted key to the view waiting on it and re-enters `createSurface()`.
///
/// Entries are WEAK. A queued pane the user closed, or one whose window went away before its turn, must be
/// dropped rather than resurrected by its own grant, and the view must never keep the launch queue alive.
@MainActor
final class SpawnRegistry {
    /// The pacer this registry routes for. Unarmed until a launch restore arms it, and passthrough again
    /// once the queue drains, so a pane created later never waits.
    let pacer: SpawnPacer

    private struct Entry {
        weak var view: GhosttySurfaceView?
    }

    private var entries: [UUID: Entry] = [:]

    init(pacer: SpawnPacer) {
        self.pacer = pacer
        pacer.onGrant = { [weak self] key in self?.grant(key) }
    }

    /// Queues `view` under `key` when its provider says the pane replays a program, and otherwise drops the
    /// key from the expected order. Arming runs before any provider exists, so a pane that spawns unpaced
    /// must discard its key or the queue waits on a request it will never make. A pane with no key — a fresh
    /// or runtime split — was never expected and needs neither.
    func enqueue(_ view: GhosttySurfaceView, key: UUID?, provider: LaunchSeedProvider) {
        guard let key else { return }
        guard provider.shouldPace else {
            pacer.discard(key)
            return
        }
        entries[key] = Entry(view: view)
        view.useSpawnPacer(pacer, key: key)
    }

    /// The pane queued under `key`, nil once it is granted or its view deallocates.
    func view(for key: UUID) -> GhosttySurfaceView? { entries[key]?.view }

    /// Spawns the granted pane against the bounds it has NOW and forgets it: a key is granted once, and a
    /// view already gone is simply dropped. Only a pane DENIED earlier is resumed here. A burst or expedited
    /// key is granted synchronously inside the pane's own request, while its `createSurface` is still on
    /// the stack, and that caller consumes the grant; re-entering would spawn the surface twice.
    func grant(_ key: UUID) {
        guard let view = entries.removeValue(forKey: key)?.view, view.awaitingSpawnPermit else { return }
        view.createSurface()
    }
}
