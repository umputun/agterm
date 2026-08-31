import Foundation

// Per-session durable state the sidebar and title bar project: flagged working-set membership and the
// background watermark. Split out of `AppStore.swift` for the file size limit.
extension AppStore {
    /// Sets (or clears) a session's flag — the durable flagged working-set membership the flat sidebar view
    /// projects — and persists. Clean no-op for an unknown id or a matching flag, so delta-computed callers
    /// stay idempotent. Unflagging narrows in `.flagged` mode (dropping the row rendering the active session),
    /// hence `reselectIfSelectionHidden`; in tree mode it only repairs a selection stranded by something else.
    public func setFlag(_ on: Bool, forSession id: UUID) {
        guard let session = session(withID: id), session.flagged != on else { return }
        session.flagged = on
        pruneSidebarSelection()
        reselectIfSelectionHidden()
        save()
    }

    /// Sets (or clears) multiple sessions' flags in one save. Unknown ids are ignored.
    public func setFlag(_ on: Bool, forSessions ids: [UUID]) {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else { return }
        var changed = false
        for workspace in workspaces {
            for session in workspace.sessions where targetIDs.contains(session.id) && session.flagged != on {
                session.flagged = on
                changed = true
            }
        }
        if changed {
            pruneSidebarSelection()
            reselectIfSelectionHidden() // the batch can unflag the active session too
            save()
        }
    }

    /// Sets (or clears) a session's background watermark and persists it; clean no-op for an unknown id or an
    /// unchanged spec, so a repeated `session.background` is idempotent. Returns whether the spec CHANGED, so
    /// the app target can gate its (retained, teardown-only-freed) per-surface config apply on a real change
    /// — without that a scripted set-loop keeps appending owned configs. The store owns only the spec; the
    /// C-boundary apply lives app-side in `ControlServer`/`GhosttySurfaceView`.
    @discardableResult
    public func setBackgroundWatermark(_ watermark: BackgroundWatermark?, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), session.backgroundWatermark != watermark else { return false }
        let previous = session.backgroundWatermark
        session.backgroundWatermark = watermark
        // a `.text` watermark owns a rendered `<id>.png`; switching away leaves it unreferenced. `clear` and
        // teardown sweep the same file, so this is only the eager reclaim for text→image/nil.
        if previous?.kind == .text, watermark?.kind != .text {
            WatermarkStorage.removeRenderedText(sessionID: id)
        }
        save()
        return true
    }

    /// Unflags every session in one `save()`; no write when nothing is flagged. Backs Clear Flagged and the
    /// `session.flag clear` control mode. No `reselectIfSelectionHidden`, unlike the `setFlag` mutators:
    /// clearing EVERY flag leaves the list empty, so there is nowhere to move — a partial clear would need it.
    public func clearFlags() {
        var changed = false
        for workspace in workspaces {
            for session in workspace.sessions where session.flagged {
                session.flagged = false
                changed = true
            }
        }
        if changed {
            pruneSidebarSelection()
            save()
        }
    }
}
