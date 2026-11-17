extension WindowLibrary {
    /// restartCounts counts this Mac's terminal rows in its open windows, pages excluded, and whether any open
    /// session comes from another host.
    public func restartCounts() -> (localSessions: Int, remote: Bool) {
        var local = 0
        var remote = false
        for info in windows {
            guard let store = stores[info.id] else { continue }
            if info.isRemote {
                remote = true
                continue
            }
            for session in store.workspaces.flatMap(\.sessions) {
                if session.remoteHost != nil {
                    remote = true
                } else if session.content != .page {
                    local += 1
                }
            }
        }
        return (local, remote)
    }
}
