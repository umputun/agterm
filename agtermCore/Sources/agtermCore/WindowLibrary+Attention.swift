import Foundation

/// One row of the cross-window attention list: a non-idle session and the open window it lives in.
public struct AttentionEntry: Identifiable {
    public let window: WindowInfo
    public let session: Session

    public var id: UUID { session.id }
}

/// The cross-window attention feed behind the titlebar bell and the `.attention` palette, split out of
/// `WindowLibrary.swift` for the file-length limit.
extension WindowLibrary {
    /// Every open window's non-idle sessions in one `AppStore.attentionPrecedes` order, each paired with
    /// its window. Equals the active store's `attentionSessions` with one window open. Reads
    /// `openSetVersion` so an observer re-fires when a background window opens or closes, not only when a
    /// session's status changes.
    public var attentionAcrossWindows: [AttentionEntry] {
        _ = openSetVersion
        return windows
            .compactMap { info in stores[info.id].map { (info, $0) } }
            .flatMap { info, store in store.attentionSessions.map { AttentionEntry(window: info, session: $0) } }
            .sorted { AppStore.attentionPrecedes($0.session, $1.session) }
    }

    /// The next/previous attention target across every open window, for GUI navigation under
    /// `AppStore.attentionNavigationAcrossWindows`. Walks windows in library order and each window's
    /// `navigableSessions` in sidebar order, so every window keeps its own filter and stop rule. Scans
    /// from `source`'s selection, wrapping and excluding it; with no selection it enters at the first
    /// (forward) or last (backward) candidate. `eligible` skips a window under a modal cover without
    /// stopping the scan; `source` always counts, since the caller gates it. Nil when nothing else stops.
    public func attentionStep(from source: UUID, forward: Bool,
                              eligible: (UUID) -> Bool) -> (windowID: UUID, sessionID: UUID)? {
        let candidates = windows.flatMap { info -> [(window: UUID, store: AppStore, session: Session)] in
            guard let store = stores[info.id], info.id == source || eligible(info.id) else { return [] }
            return store.navigableSessions.map { (info.id, store, $0) }
        }
        let count = candidates.count
        guard count > 0 else { return nil }
        let selected = stores[source]?.selectedSessionID
        let current = candidates.firstIndex { $0.window == source && $0.session.id == selected }
        let step = forward ? 1 : -1
        let start = current ?? (forward ? -1 : count)
        for k in 1...count {
            let idx = ((start + step * k) % count + count) % count
            if let current, idx == current { break }
            let candidate = candidates[idx]
            if candidate.store.stopsAttentionNavigation(candidate.session) {
                return (candidate.window, candidate.session.id)
            }
        }
        return nil
    }

    public func attentionLabel(_ entry: AttentionEntry) -> String {
        stores[entry.window.id]?.listLabel(for: entry.session) ?? entry.session.displayName
    }

    /// The row subtitle every attention surface shares: "`workspace` · detail" as the per-window lists
    /// read, led by the window name once more than one window is open, since only then does a row need
    /// to say where it lives.
    public func attentionSubtitle(_ entry: AttentionEntry) -> String {
        let workspace = stores[entry.window.id]?.workspace(forSession: entry.session.id)?.name ?? ""
        let detail = "\(workspace) · \(entry.session.switcherDetail)"
        return openIDs().count > 1 ? "\(entry.window.name) · \(detail)" : detail
    }
}
