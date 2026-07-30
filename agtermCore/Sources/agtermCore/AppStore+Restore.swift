import Foundation

// MARK: - Per-session restore-command override

/// The persisted per-pane restore-command override behind the control channel's `session.restore`. Split out
/// of the main `AppStore` body for the file-size budget, like `AppStore+Status.swift`; the stored state lives
/// on `Session` and this operates over it.
extension AppStore {
    /// Sets a pane's PERSISTED restore-command override, the single mutation point for the control channel's
    /// `session.restore`. Tri-state `value`: nil = no override (auto-capture), `""` = pinned to nothing (a
    /// plain shell), `"cmd"` = run that shell line on the next launch. Persists immediately — the override
    /// must survive a SIGKILL, or a hook's write is lost before the next launch reads it. Idempotent like
    /// `setFlag`: an unchanged value writes nothing and skips the save. No-op for an unknown id.
    ///
    /// It deliberately does NOT touch the pending slots: a write during this run must not execute during
    /// this run. Only an app-bootstrap restore copies the persisted value into `pendingRestoreCommand`
    /// (see `session(from:launchRestore:)`), which is what the surface factories consume. `.scratch` is
    /// rejected at the command layer (the scratch terminal is never restored), so it is not handled here.
    ///
    /// Returns whether the requested value is now on disk, so a caller can refuse to acknowledge a write
    /// that never landed — unlike the rest of the store, which mutates and lets `save()` swallow the error.
    /// The payload is an arbitrary shell line re-typed on every launch, so a false "cleared" would leave the
    /// OLD command running forever. A failed save is ROLLED BACK in memory, keeping the value matching disk
    /// and stopping the unchanged-value guard from swallowing the retry. `false` also covers the two
    /// nothing-to-write cases the command layer already rejects (an unknown id, the scratch pane).
    @discardableResult
    public func setRestoreCommand(_ value: String?, pane: StatusPane, forSession id: UUID) -> Bool {
        guard let session = session(withID: id) else { return false }
        let field: ReferenceWritableKeyPath<Session, String?>
        switch pane {
        case .left: field = \.restoreCommand
        case .right: field = \.splitRestoreCommand
        case .scratch: return false
        }
        let previous = session[keyPath: field]
        guard previous != value else { return true }
        session[keyPath: field] = value
        guard saveChecked() else {
            session[keyPath: field] = previous
            return false
        }
        return true
    }
}
