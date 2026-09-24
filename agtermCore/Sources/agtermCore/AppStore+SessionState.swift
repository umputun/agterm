import Foundation

// Per-session durable state the sidebar and title bar project: flagged working-set membership, the
// title-bar context, and the background watermark. Split out of `AppStore.swift` for the file size limit.
extension AppStore {
    /// Sets (or clears) a session's flag — the durable flagged working-set membership the flagged sidebar view
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

    /// Sets (or clears) a session's title-bar context — what the session is FOR — and persists it. Clean
    /// no-op for an unknown id or an unchanged value, so a re-set of the same string neither saves nor
    /// emits and a scripted loop stays quiet. Returns whether it CHANGED. `context` arrives already
    /// trimmed and validated by `Session.validateContext`; nil clears.
    @discardableResult
    public func setContext(_ context: String?, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), session.context != context else { return false }
        let previous = session.effectiveContext
        session.context = context
        save()
        presentationHub?.publish(.context(context), session: id)
        if previous != session.effectiveContext { scheduleTreeChanged() }
        return true
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

    /// setBackgroundWatermark writes the session default when `pane` is nil, leaving pane overrides in
    /// place, or that pane's override, where nil returns the pane to inheriting. Returns whether it changed.
    @discardableResult
    public func setBackgroundWatermark(_ watermark: BackgroundWatermark?, forSession id: UUID,
                                       pane: StatusPane? = nil) -> Bool {
        guard let session = session(withID: id) else { return false }
        let previous = pane.map { session.paneBackgrounds[$0] } ?? session.backgroundWatermark
        guard previous != watermark else { return false }
        if let pane {
            session.paneBackgrounds[pane] = watermark
        } else {
            session.backgroundWatermark = watermark
        }
        // a `.text` watermark owns a rendered PNG that switching away leaves unreferenced. for a pane override
        // this is the only removal short of the pane closing: `clear --pane` sweeps nothing app-side.
        if previous?.kind == .text, watermark?.kind != .text {
            if let pane {
                session.backgroundFileKey(for: pane).map { WatermarkStorage.removeRenderedText(sessionID: id, paneKey: $0) }
            } else {
                WatermarkStorage.removeRenderedText(sessionID: id)
            }
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
