import Foundation

extension AppStore {
    /// Persists the current state eagerly, after every structural mutation and on terminate. Cancels any
    /// pending debounced save first, so a `save()` (incl. the quit-flush) writes the latest snapshot and no
    /// stale write fires afterward. A failure is logged and swallowed — a disk error must not kill the model.
    public func save() {
        saveChecked()
    }

    /// `save()` that REPORTS whether the write landed, for a caller whose acknowledgement must not outrun the
    /// disk. `setRestoreCommand` is the one today: a "cleared" ack that never reached disk would leave the
    /// old shell line armed on every launch. `save()` is this with the result discarded, so they can't drift.
    @discardableResult
    func saveChecked() -> Bool {
        saveDebouncer.cancel()
        do {
            try persistence.save(snapshot())
            snapshotUnsaved = false
            snapshotDidSave?()
            return true
        } catch {
            snapshotUnsaved = true
            log("save failed: \(error)")
            return false
        }
    }

    /// Debounces a `save()`, coalescing the rapid selection/font writes; used only by
    /// `selectSession`/`setFontSize`, while structural mutations call `save()` immediately.
    func scheduleSave() {
        saveDebouncer.schedule(after: AppStore.saveDebounceInterval) { [weak self] in
            self?.save()
        }
    }

    /// Drops any pending debounced save WITHOUT writing, unlike `save()`, which cancels then writes. Used when
    /// the owning window is being deleted (`WindowLibrary.removeWindow`): a save scheduled just before the
    /// delete must be dropped, else it fires afterward and re-creates the per-window file as an orphan.
    public func cancelPendingSave() {
        saveDebouncer.cancel()
    }
}
