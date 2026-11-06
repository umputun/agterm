/// TitleAdmission decides which OSC titles a pane hands to the main thread. A title identical to the last
/// one queued is skipped while that one still waits, since it would apply the same string; libghostty
/// delivers every title a program writes, and a program writing one in a loop otherwise queues a main
/// block per write. One value per pane, guarded by the caller: admit runs off-main, complete on main.
public struct TitleAdmission: Sendable {
    private var lastQueued: String?
    private var pending = 0

    public init() {}

    /// admit reports whether `title` must be queued, recording it as the last queued title when it is.
    public mutating func admit(_ title: String) -> Bool {
        if pending > 0, title == lastQueued { return false }
        lastQueued = title
        pending += 1
        return true
    }

    /// complete marks one queued title as taken off the queue.
    public mutating func complete() {
        pending = max(0, pending - 1)
    }
}
