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

    /// The row subtitle every attention surface shares: "`workspace` · detail" as the per-window lists
    /// read, led by the window name once more than one window is open, since only then does a row need
    /// to say where it lives.
    public func attentionSubtitle(_ entry: AttentionEntry) -> String {
        let workspace = stores[entry.window.id]?.workspace(forSession: entry.session.id)?.name ?? ""
        let detail = "\(workspace) · \(entry.session.subtitleDetail)"
        return openIDs().count > 1 ? "\(entry.window.name) · \(detail)" : detail
    }
}
