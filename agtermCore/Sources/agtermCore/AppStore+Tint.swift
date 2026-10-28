import Foundation

// Sidebar row tints for sessions and workspaces: the store seam `session.tint`, `workspace.tint`, the row
// menus and the palette share.
extension AppStore {
    /// setTint replaces a session's tint (nil clears) and persists. No-op for an unknown id or an unchanged
    /// value, so a repeated set neither saves nor emits; returns whether it changed.
    @discardableResult
    public func setTint(_ tint: SidebarTint?, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), session.tint != tint else { return false }
        session.tint = tint
        save()
        scheduleTreeChanged()
        return true
    }

    /// setTint replaces a workspace's own tint (nil clears) and persists, with the session form's no-op rule.
    @discardableResult
    public func setTint(_ tint: SidebarTint?, forWorkspace id: UUID) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces[index].tint != tint else {
            return false
        }
        workspaces[index].tint = tint
        save()
        scheduleTreeChanged()
        return true
    }

    /// setTintColor gives every session in `ids` the color (nil clears), keeping each tinted row's own
    /// parts and starting an untinted one on the icon. One save for the whole batch.
    public func setTintColor(_ color: TintColor?, forSessions ids: [UUID]) {
        applyTints(ids) { SidebarTint.recolor($0, to: color) }
    }

    /// setTintParts shows each tinted session's own color on `parts`. An untinted session is left alone, so
    /// no row stores a placement it does not show.
    public func setTintParts(_ parts: Set<TintPart>, forSessions ids: [UUID]) {
        applyTints(ids) { SidebarTint.place($0, on: parts) }
    }

    private func applyTints(_ ids: [UUID], _ next: (SidebarTint?) -> SidebarTint?) {
        var changed = false
        for id in ids {
            guard let session = session(withID: id) else { continue }
            let tint = next(session.tint)
            guard tint != session.tint else { continue }
            session.tint = tint
            changed = true
        }
        guard changed else { return }
        save()
        scheduleTreeChanged()
    }
}
