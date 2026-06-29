import Foundation
import Observation

/// A relative step through the flattened session list for keyboard navigation.
/// `next`/`previous` step one and stop at the ends (no wrap), `first`/`last` jump to a tree end.
/// `nextAttention`/`previousAttention` step through only the sessions needing attention
/// (status `blocked` or `completed`), wrapping around.
public enum SessionNavigation: Sendable { case next, previous, first, last, nextAttention, previousAttention }

extension SessionNavigation {
    /// Maps a control-channel direction string to a case. The CLI uses `prev`; the enum case is
    /// `.previous`, so both spellings are accepted. Returns nil for an unknown string.
    public init?(wire: String) {
        switch wire {
        case "next": self = .next
        case "prev", "previous": self = .previous
        case "first": self = .first
        case "last": self = .last
        case "next-attention": self = .nextAttention
        case "prev-attention", "previous-attention": self = .previousAttention
        default: return nil
        }
    }
}

/// The whole app state: the workspace tree and the current selection.
///
/// `@Observable @MainActor` so SwiftUI views observe mutations and all model
/// access is main-actor isolated (implicitly `Sendable` via isolation). Selection
/// is a single `Session.ID?` — workspace rows are non-selectable disclosure
/// headers, so one id is enough; the owning workspace is derived.
@Observable
@MainActor
public final class AppStore {
    public var workspaces: [Workspace]
    public var selectedSessionID: UUID?

    /// Whether this window's sidebar is shown. Per-window UI state, persisted in `Snapshot` (restored on
    /// relaunch); the custom split owns visibility, so the toolbar button, the View menu item, the action
    /// palette, and the `sidebar` control command all flip this one flag.
    public var sidebarVisible = true

    /// Which view this window's sidebar renders: the normal workspace tree or a flat list of the
    /// flagged working-set. Per-window UI state, persisted in `Snapshot` (restored on relaunch);
    /// flipped by the bottom-bar toggle, the View menu, the action palette, and the `sidebar.mode`
    /// control command via `setSidebarMode(_:)`.
    public var sidebarMode: SidebarMode = .tree

    /// The workspace the sidebar tree is focused (zoomed) on, or nil for the full tree. Per-window UI
    /// state, persisted in `Snapshot` (restored on relaunch). When set, the tree renders only that
    /// workspace (see `visibleWorkspaces`); orthogonal to `sidebarMode` (flagged mode ignores focus).
    /// Flipped by the workspace row menu, the bottom-bar pill, the View menu, the palette, and the
    /// `workspace.focus` control command via `setFocusedWorkspace(_:)`. Auto-cleared when the focused
    /// workspace is removed or when a session outside it becomes selected.
    public var focusedWorkspaceID: UUID?

    /// This window's sidebar width in points. Per-window UI state, persisted in `Snapshot`. Driven by the
    /// sidebar divider drag (clamped to `sidebarWidthMin...sidebarWidthMax`); restored on relaunch.
    public var sidebarWidth: Double = AppStore.sidebarWidthDefault

    /// The sidebar width default and drag/restore bounds, shared by the view's divider drag and the
    /// `restore()` clamp so the two can't drift (and a hand-edited snapshot can't drive an out-of-range frame).
    public static let sidebarWidthDefault: Double = 220
    public static let sidebarWidthMin: Double = 160
    public static let sidebarWidthMax: Double = 560

    /// The persisted split-divider left-pane fraction bounds. The live capture skips degenerate extremes
    /// outside this range and `restore()` clamps to it, so the on-disk ratio is always within bounds.
    public static let splitRatioMin: Double = 0.05
    public static let splitRatioMax: Double = 0.95
    /// The even split fraction a never-moved divider renders at (the `HSplitView` default); the base for a
    /// relative `session.resize` when `Session.splitRatio` is still nil.
    public static let splitRatioDefault: Double = 0.5

    /// Clamp a left-pane split fraction to `splitRatioMin...splitRatioMax`.
    public static func clampSplitRatio(_ ratio: Double) -> Double {
        min(splitRatioMax, max(splitRatioMin, ratio))
    }

    /// Most-recently-selected session ids, front = current. Drives the Ctrl-Tab switcher
    /// (`items[1]` is the previous session). `@ObservationIgnored`: read imperatively by the
    /// switcher, not by any SwiftUI view, and not persisted.
    @ObservationIgnored public private(set) var sessionRecency = RecencyStack<UUID>()

    @ObservationIgnored private let persistence: PersistenceStore

    /// Coalesces the high-frequency selection/font saves: a click-storm or a font ramp schedules one
    /// write ~0.3 s after the burst settles instead of hitting disk per event. `save()` cancels any
    /// pending scheduled save, so the quit-flush (`saveAllOpen()` → `save()`) still captures the latest.
    @ObservationIgnored private let saveDebouncer = Debouncer()

    /// The quiet window before a scheduled (selection/font) save writes to disk.
    private static let saveDebounceInterval: TimeInterval = 0.3

    public init(workspaces: [Workspace] = [], selectedSessionID: UUID? = nil,
                persistence: PersistenceStore = PersistenceStore()) {
        self.workspaces = workspaces
        self.selectedSessionID = selectedSessionID
        self.persistence = persistence
    }

    /// The currently selected session, derived from `selectedSessionID`.
    public var activeSession: Session? {
        guard let selectedSessionID else { return nil }
        return session(withID: selectedSessionID)
    }

    /// The workspace a new session should land in: the selected session's workspace, else the
    /// last workspace (nil when there are no workspaces). Drives both the bottom bar's add
    /// actions and the File menu's New Session / Open Directory.
    public var currentWorkspaceID: UUID? {
        if let selectedSessionID, let workspace = workspace(forSession: selectedSessionID) {
            return workspace.id
        }
        return workspaces.last?.id
    }

    /// The auto-generated name for the next new workspace (`workspace 1`, `workspace 2`, …).
    public var defaultWorkspaceName: String {
        "workspace \(workspaces.count + 1)"
    }

    /// Creates a workspace and appends it. Clears any active focus so the new (empty)
    /// workspace is immediately visible — without this `visibleWorkspaces` would still
    /// return only the focused one and the new workspace would be silently hidden until
    /// the user manually unfocuses (the same auto-reveal contract as `addSession`).
    @discardableResult
    public func addWorkspace(name: String) -> Workspace {
        let workspace = Workspace(name: name)
        workspaces.append(workspace)
        focusedWorkspaceID = nil
        save()
        return workspace
    }

    /// The first workspace whose name exactly equals `name` (case-sensitive, trimmed), or nil when none
    /// matches or `name` is blank. Backs `session.new --workspace-name` (addressing a workspace by its
    /// sidebar label instead of an id).
    public func workspace(named name: String) -> Workspace? {
        guard let needle = name.trimmedOrNil else { return nil }
        return workspaces.first { $0.name == needle }
    }

    /// The workspace named `name`, created if none exists (idempotent reuse-or-create). Returns nil only
    /// when `name` is blank. Backs `session.new --workspace-name … --create-workspace`.
    @discardableResult
    public func ensureWorkspace(named name: String) -> Workspace? {
        guard let needle = name.trimmedOrNil else { return nil }
        return workspace(named: needle) ?? addWorkspace(name: needle)
    }

    /// Creates a session in the given workspace, appends it, and selects it.
    /// An optional `name` seeds the session's `customName` (trimmed; blank clears it
    /// to the auto basename, matching `renameSession`). Returns nil if no workspace matches.
    @discardableResult
    public func addSession(toWorkspace workspaceID: UUID, cwd: String, command: String? = nil, name: String? = nil) -> Session? {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let session = Session(initialCwd: cwd, customName: name?.trimmedOrNil)
        session.initialCommand = command
        workspaces[index].sessions.append(session)
        selectedSessionID = session.id
        autoUnfocusIfOutsideFocus(session.id) // a control-driven add into another workspace must reveal it
        recordRecency()
        save()
        return session
    }

    /// Selects a session (or clears the selection when passed nil) and persists.
    /// A non-nil id that matches no session is ignored, leaving the current
    /// selection untouched; nil always deselects. Backs the sidebar's
    /// `List(selection:)` so a click persists (debounced ~0.3 s) rather than waiting
    /// for the next structural mutation. Visiting a session clears its unseen badge. An
    /// `autoReset` agent indicator (the one-time `completed` flash) is reset to idle on
    /// BOTH the session moved to (you've seen it) and the one moved from (it must not
    /// persist once you leave it); a non-`autoReset` indicator (active/blocked) is left
    /// untouched (keep-state).
    public func selectSession(_ sessionID: UUID?) {
        if let sessionID, session(withID: sessionID) == nil { return }
        let previous = selectedSessionID
        selectedSessionID = sessionID
        autoUnfocusIfOutsideFocus(sessionID)
        if let sessionID { clearUnseen(sessionID) }
        clearAutoResetIndicator(sessionID) // visit: you've seen it
        clearAutoResetIndicator(previous)  // leave: a one-time status must not linger on the row you left
        recordRecency()
        scheduleSave() // selection fires on every click/keystroke — coalesce the writes
    }

    /// Clears focus when the newly selected session lives outside the focused workspace, so an explicit
    /// cross-set select (`session.select <id>` of a hidden session, a notification reveal, a move/close
    /// that reselects elsewhere) reveals its target — the active session is then always inside the
    /// visible set. Session navigation (`navigateSession`/`session.go`, Ctrl-Tab, attention-nav) is now
    /// scoped to the filtered set (`navigableSessions`), so its targets are always in-set and never
    /// trip this — it stays the safety net only for the explicit cross-set cases. No-op when unfocused,
    /// when nothing is selected, or when the selection is inside the focused workspace. Persistence
    /// rides the caller's `selectSession` save.
    private func autoUnfocusIfOutsideFocus(_ sessionID: UUID?) {
        guard let focusedWorkspaceID, let sessionID else { return }
        if workspace(forSession: sessionID)?.id != focusedWorkspaceID { self.focusedWorkspaceID = nil }
    }

    /// Reset a session's agent indicator to idle when it is marked `autoReset` (the one-time `completed`
    /// flash). No-op for nil / an unknown id / a non-autoReset indicator.
    private func clearAutoResetIndicator(_ id: UUID?) {
        guard let id, let session = session(withID: id), session.agentIndicator.autoReset else { return }
        session.agentIndicator = AgentIndicator()
    }

    /// Clears a session's unseen-notification badge — it's been looked at. No-op for an unknown id.
    /// Not persisted (the count is ephemeral), so it never triggers a `save()`.
    public func clearUnseen(_ sessionID: UUID) {
        session(withID: sessionID)?.unseenCount = 0
    }

    /// Sets a session's agent status indicator (the sidebar status glyph). The single mutation point
    /// for the control channel's `session.status`. Stamps `statusChangedAt` with the current time on any
    /// non-idle status (the attention list's newest-first sort key) and clears it on idle. No-op for an
    /// unknown id. Not persisted (the indicator is ephemeral), so it never triggers a `save()`.
    public func setAgentIndicator(_ indicator: AgentIndicator, forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        session.agentIndicator = indicator
        session.statusChangedAt = indicator.status == .idle ? nil : Date()
    }

    /// Pushes the current selection to the front of the recency stack (the Ctrl-Tab order).
    /// No-op when nothing is selected.
    private func recordRecency() {
        if let selectedSessionID { sessionRecency.push(selectedSessionID) }
    }

    /// Sets a session's custom name. An empty (or whitespace-only) name clears
    /// `customName` to nil, reverting the row to the auto basename.
    public func renameSession(_ sessionID: UUID, to name: String) {
        guard let session = session(withID: sessionID) else { return }
        session.customName = name.trimmedOrNil
        save()
    }

    /// Renames a workspace. An empty (or whitespace-only) name is ignored —
    /// workspaces have no auto fallback, so a blank name is rejected.
    public func renameWorkspace(_ workspaceID: UUID, to name: String) {
        guard let trimmed = name.trimmedOrNil, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].name = trimmed
        save()
    }

    /// Removes a session, tears down its surface, and — if it was the active
    /// session — reselects a neighbor (next in the same workspace, else the
    /// previous, else any remaining session, else nil).
    public func closeSession(_ sessionID: UUID) {
        guard let location = location(ofSession: sessionID) else { return }
        let wasActive = selectedSessionID == sessionID
        let removed = workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex)
        removed.surface?.teardown()
        removed.splitSurface?.teardown()
        removed.overlaySurface?.teardown()
        removed.scratchSurface?.teardown()
        WatermarkStorage.removeRenderedText(sessionID: sessionID) // drop any rendered .text PNG; the session is gone
        sessionRecency.remove(sessionID)
        if wasActive {
            selectedSessionID = reselectionTarget(after: location)
            autoUnfocusIfOutsideFocus(selectedSessionID) // the neighbor may live outside the focused workspace
            recordRecency()
        }
        save()
    }

    /// Whether a workspace may be removed: one workspace is always kept, so removal is
    /// allowed only when more than one exists.
    public var canRemoveWorkspace: Bool { workspaces.count > 1 }

    /// Removes a workspace and every session in it, tearing down each session's surfaces
    /// and pruning them from the recency stack. No-ops unless more than one workspace
    /// exists (the last one is kept). If the active session lived in the removed
    /// workspace, reselects the first session of a remaining workspace (the one that
    /// shifted into the removed slot, else the first non-empty workspace), or nil when
    /// no sessions remain.
    public func removeWorkspace(_ workspaceID: UUID) {
        guard canRemoveWorkspace, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let removingActive = selectedSessionID.map { id in workspaces[index].sessions.contains { $0.id == id } } ?? false
        for session in workspaces[index].sessions {
            session.surface?.teardown()
            session.splitSurface?.teardown()
            session.overlaySurface?.teardown()
            session.scratchSurface?.teardown()
            WatermarkStorage.removeRenderedText(sessionID: session.id) // drop any rendered .text PNG; the session is gone
            sessionRecency.remove(session.id)
        }
        if focusedWorkspaceID == workspaceID { focusedWorkspaceID = nil } // the focused root is gone
        workspaces.remove(at: index)
        if removingActive {
            let fallbackIndex = min(index, workspaces.count - 1)
            selectedSessionID = workspaces[fallbackIndex].sessions.first?.id
                ?? workspaces.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
            autoUnfocusIfOutsideFocus(selectedSessionID) // the reselected session may live outside the focused workspace
            recordRecency()
        }
        save()
    }

    /// Toggles the one-level split for a session. The second pane's surface is created
    /// lazily by the detail pane on first show and kept alive when hidden, so this only
    /// flips the flag. The flag is persisted, so the split is restored on relaunch.
    public func toggleSplit(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.isSplit.toggle()
        // opening marks the session as having a split and moves focus to the new (right) pane; hiding
        // (toggling off) leaves `hasSplit` and `splitFocused` set so the split indicators persist and
        // the focused pane is the one shown maximized. Only `closeSplit` clears them.
        if session.isSplit {
            session.hasSplit = true
            session.splitFocused = true
        }
        save()
    }

    /// Sets a session's split-divider left-pane fraction to `ratio`, clamped to the bounds, and persists.
    /// Returns the applied (clamped) fraction, or nil when the id is unknown. Moving the LIVE divider is
    /// driven separately by the caller (`session.resize` posts `.agtermApplySplitRatio` to the pane view) —
    /// this is control-native, so there is no GUI surface that goes through `AppActions`.
    @discardableResult
    public func applySplitRatio(_ ratio: Double, forSession id: UUID) -> Double? {
        guard let session = session(withID: id) else { return nil }
        let applied = AppStore.clampSplitRatio(ratio)
        session.splitRatio = applied
        save()
        return applied
    }

    /// Closes the split pane: hides it AND tears down its surface, so a subsequent split
    /// starts a fresh shell. Used when the split shell exits on its own; resets the focus flag so a
    /// stale `splitFocused` doesn't point the collapsed view at the gone pane.
    public func closeSplit(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.isSplit = false
        session.hasSplit = false
        session.splitFocused = false
        session.splitSurface?.teardown()
        session.splitSurface = nil
        session.splitCwd = nil
        session.splitTitle = nil
        session.initialSplitCwd = nil
        session.splitRatio = nil // tearing down the split clears its geometry too, so a fresh split opens even
        // a search bar pinned to the torn-down split surface would otherwise stay stuck (the weak
        // `searchSurface` zeroes but `searchActive` stays true), so reset search on the surviving session.
        session.clearSearch()
        save()
    }

    /// The primary pane's shell exited. If a split pane is alive it becomes the session's single
    /// (non-split) pane and the session survives; otherwise the session is closed. The survivor stays
    /// in the `splitSurface` slot, shown maximized via `splitFocused`, and its cwd is promoted to the
    /// session's so a restart restores the single session in the right directory. Called by the primary
    /// surface's `onExit`.
    public func closePrimaryPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard session.splitSurface != nil else {
            closeSession(sessionID)
            return
        }
        session.surface?.teardown()
        session.surface = nil
        session.isSplit = false
        session.hasSplit = false
        session.splitFocused = true
        session.splitRatio = nil // promoted to a single pane; a later split should open even, not stale
        // the command pane is gone — the promoted survivor is a plain shell, so drop the creation command
        // or a restart would resurrect the exited command instead of restoring the promoted shell.
        session.initialCommand = nil
        if let cwd = session.splitCwd { session.currentCwd = cwd }
        // the primary surface (possibly the search owner) is torn down while the session survives as the
        // promoted split, so reset search rather than leave a stuck bar pinned to the gone primary.
        session.clearSearch()
        save()
    }

    /// The split pane's shell exited. If the primary is alive the split collapses to it (`closeSplit`);
    /// otherwise the primary already exited, so this was the last pane and the session is closed. Called
    /// by the split surface's `onExit`.
    public func closeSplitPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard session.surface != nil else {
            closeSession(sessionID)
            return
        }
        closeSplit(sessionID)
    }

    /// Opens an ephemeral overlay terminal on a session running `command` (e.g. a TUI). The overlay
    /// surface is created lazily by the detail pane and runs the command as its process; when the
    /// program exits, `closeOverlay` tears it down. No-op (returns false) when the session is unknown
    /// or already has an overlay open. NOT persisted — the overlay never survives a relaunch.
    ///
    /// `sizePercent` (clamped to 1...100) requests a *floating* overlay: an opaque, framed panel sized
    /// to that percent of the pane, with the session still visible behind it. nil gives the default
    /// full-pane overlay that hides the session.
    @discardableResult public func openOverlay(_ sessionID: UUID, command: String, cwd: String? = nil,
                                               wait: Bool = false, sizePercent: Int? = nil) -> Bool {
        guard let session = session(withID: sessionID), !session.overlayActive else { return false }
        session.overlayCommand = command
        session.overlayCwd = cwd
        session.overlayWait = wait
        session.overlayExitCode = nil
        session.overlaySizePercent = sizePercent.map { min(100, max(1, $0)) }
        session.overlayActive = true
        return true
    }

    /// Records the overlay program's exit status (parsed app-side from the wrapper's temp file on the
    /// surface's teardown) so `session.overlay.result` can report it after the overlay closes. No-op
    /// for an unknown session.
    public func recordOverlayExit(_ sessionID: UUID, code: Int) {
        session(withID: sessionID)?.overlayExitCode = code
    }

    /// Closes the overlay terminal: hides it AND tears down its surface (unlike the split, the overlay
    /// is never kept alive — it is ephemeral). Used both on explicit close and when the overlay's
    /// program exits on its own. No-op (returns false) when there is no overlay.
    @discardableResult public func closeOverlay(_ sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), session.overlayActive else { return false }
        session.overlayActive = false
        session.overlaySurface?.teardown()
        session.overlaySurface = nil
        session.overlayCommand = nil
        session.overlayCwd = nil
        session.overlayWait = false
        session.overlaySizePercent = nil
        return true
    }

    /// Toggles the scratch terminal for a session — a third, full-overlay login shell. The scratch
    /// surface is created lazily by the detail pane on first show and, like the split, kept alive when
    /// hidden (this only flips `scratchActive`), so a re-show reuses the same shell. Not persisted, so
    /// no `save()`. No-op for an unknown session.
    public func toggleScratch(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.scratchActive.toggle()
    }

    /// Closes the scratch terminal: hides it AND tears down its surface (so a subsequent show starts a
    /// fresh shell). Used on the scratch shell's own `exit` and on session/workspace/window teardown.
    /// No-op (returns false) when there is no scratch surface.
    @discardableResult public func closeScratch(_ sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), let scratch = session.scratchSurface else { return false }
        session.scratchActive = false
        // if the open search bar is pinned to the scratch being torn down, reset search rather than leave a
        // stuck, no-op bar (the weak `searchSurface` zeroes but `searchActive` stays true) — mirrors the
        // closeSplit/closePrimaryPane handling. Guarded on identity so a search owned by the main/split pane
        // (the scratch can cover a session whose pane opened search) survives the scratch teardown.
        if session.searchSurface === scratch { session.clearSearch() }
        scratch.teardown()
        session.scratchSurface = nil
        return true
    }

    /// Moves a session to another workspace (or reorders within the same one),
    /// keeping the **same** `Session` instance so its attached surface and live
    /// shell survive. `index` is the destination position in the target's session
    /// array **after** the move's removal (clamped to bounds); nil appends.
    /// `selectedSessionID` is unaffected — the id is stable, so a moved active
    /// session stays selected. No-ops if the session or target workspace is
    /// unknown; a same-workspace move to the current slot leaves order unchanged.
    /// Moving the **active** session out of the focused workspace auto-unfocuses
    /// (the auto-reveal contract — the active session must stay inside the visible
    /// set); moving a non-active session leaves focus intact.
    public func moveSession(_ sessionID: UUID, toWorkspace targetID: UUID, at index: Int? = nil) {
        guard let source = location(ofSession: sessionID) else { return }
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }) else { return }

        let session = workspaces[source.workspaceIndex].sessions.remove(at: source.sessionIndex)
        let destination = max(0, min(index ?? workspaces[targetIndex].sessions.count, workspaces[targetIndex].sessions.count))
        workspaces[targetIndex].sessions.insert(session, at: destination)
        if sessionID == selectedSessionID { autoUnfocusIfOutsideFocus(sessionID) }
        save()
    }

    /// Reorders a session one relative step within its own workspace (`up`/`down`/`top`/`bottom`),
    /// reusing `moveSession` with the same workspace id. No-op (no write) on an unknown id or when
    /// the move would leave order unchanged (already at the end in that direction).
    public func reorderSession(_ id: UUID, _ direction: ReorderDirection) {
        guard let loc = location(ofSession: id) else { return }
        let count = workspaces[loc.workspaceIndex].sessions.count
        guard let dest = direction.destinationIndex(from: loc.sessionIndex, count: count) else { return }
        moveSession(id, toWorkspace: workspaces[loc.workspaceIndex].id, at: dest)
    }

    /// Moves a workspace to `index` among its siblings, mirroring `moveSession`'s
    /// remove/clamp/insert/save shape. `index` is the destination position **after**
    /// the move's removal (clamped to bounds). No-op on an unknown id.
    public func moveWorkspace(_ id: UUID, at index: Int) {
        guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let workspace = workspaces.remove(at: current)
        let dest = max(0, min(index, workspaces.count))
        workspaces.insert(workspace, at: dest)
        save()
    }

    /// Reorders a workspace one relative step among its siblings (`up`/`down`/`top`/`bottom`),
    /// reusing `moveWorkspace`. No-op (no write) on an unknown id or when the move would leave
    /// order unchanged (already at the end in that direction).
    public func reorderWorkspace(_ id: UUID, _ direction: ReorderDirection) {
        guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard let dest = direction.destinationIndex(from: current, count: workspaces.count) else { return }
        moveWorkspace(id, at: dest)
    }

    /// The owning workspace id, the session's index within it, and that workspace's session count, or
    /// nil for an unknown id. Lets the sidebar drag handler resolve owner + index in a single tree walk
    /// instead of re-deriving each piece, while feeding the host-free `SidebarDrop` resolver.
    public func sessionLocation(ofSession id: UUID) -> (workspace: UUID, index: Int, count: Int)? {
        guard let loc = location(ofSession: id) else { return nil }
        let workspace = workspaces[loc.workspaceIndex]
        return (workspace.id, loc.sessionIndex, workspace.sessions.count)
    }

    /// Steps the selection through the flattened VISIBLE/FILTERED session list (`navigableSessions`:
    /// the flagged set in `.flagged` mode, the focused workspace's sessions when focused, else all),
    /// in the sidebar's visual order. `next`/`previous` move one and stop at the ends (no wrap — `next`
    /// on the last session and `previous` on the first are no-ops); `first`/`last` jump to the ends of
    /// the filtered list. With no/invalid current selection, `next`/`previous` land on its first session.
    /// No-op when the filtered list is empty. Routes through `selectSession`, inheriting recency, badge
    /// clearing, persistence, and workspace derivation. Because the targets are always in-set, nav never
    /// triggers `autoUnfocusIfOutsideFocus` — that stays the safety net for an explicit cross-set select.
    public func navigateSession(_ direction: SessionNavigation) {
        let sessions = navigableSessions
        let ids = sessions.map(\.id)
        guard let first = ids.first, let last = ids.last else { return }
        let target: UUID
        switch direction {
        case .first: target = first
        case .last: target = last
        case .next, .previous:
            if let current = selectedSessionID, let i = ids.firstIndex(of: current) {
                let step = direction == .next ? 1 : -1
                let next = i + step
                guard next >= 0, next < ids.count else { return } // at an end -> stay put (no wrap)
                target = ids[next]
            } else {
                target = first // no/invalid selection -> first
            }
        case .nextAttention, .previousAttention:
            guard let found = attentionTarget(in: sessions, forward: direction == .nextAttention) else { return }
            target = found
        }
        selectSession(target)
    }

    /// The next/previous session needing attention (status `blocked` or `completed`) in the flattened
    /// order, scanning from the current selection and WRAPPING around. The current session is excluded,
    /// so repeated steps cycle through the others. With no/invalid selection the scan starts from the
    /// tree end opposite the direction. Returns nil when no other attention session exists (a no-op).
    private func attentionTarget(in sessions: [Session], forward: Bool) -> UUID? {
        let ids = sessions.map(\.id)
        let count = ids.count
        guard count > 0 else { return nil }
        let step = forward ? 1 : -1
        let curIndex = selectedSessionID.flatMap { ids.firstIndex(of: $0) }
        let start = curIndex ?? (forward ? -1 : count)
        for k in 1...count {
            let idx = ((start + step * k) % count + count) % count
            if let curIndex, idx == curIndex { break } // wrapped back to the current session, none other
            if sessions[idx].agentIndicator.status.needsAttention { return ids[idx] }
        }
        return nil
    }

    /// Records a session's terminal font size (points) and persists it. No-ops when
    /// unchanged so the cell-size event firing on a DPI change (not a font change)
    /// doesn't write. The save is debounced (~0.3 s) so a font ramp (held ⌘+/⌘−)
    /// coalesces into one write instead of hitting disk per step.
    public func setFontSize(_ sessionID: UUID, _ size: Double) {
        guard let session = session(withID: sessionID), session.fontSize != size else { return }
        session.fontSize = size
        scheduleSave()
    }

    /// Clears every session's per-session font-size override (back to the app default). Called
    /// when an appearance change is applied: the shared ghostty `update_config` resets all live
    /// surfaces to the default size, so the persisted overrides are cleared to match. No-ops (no
    /// write) when nothing was overridden.
    public func resetSessionFontSizes() {
        var changed = false
        for workspace in workspaces {
            for session in workspace.sessions where session.fontSize != nil {
                session.fontSize = nil
                changed = true
            }
        }
        if changed { save() }
    }

    /// Sets the sidebar mode and persists it. Clean no-op (no write) when the mode is unchanged, so the
    /// delta-computed control/menu callers stay idempotent.
    public func setSidebarMode(_ mode: SidebarMode) {
        guard sidebarMode != mode else { return }
        sidebarMode = mode
        save()
    }

    /// Sets (or clears) the focused workspace and persists it. Clean no-op (no write) when unchanged, so
    /// the delta-computed control/menu callers stay idempotent. Passing nil unfocuses.
    public func setFocusedWorkspace(_ id: UUID?) {
        guard focusedWorkspaceID != id else { return }
        focusedWorkspaceID = id
        save()
    }

    /// The focused workspace, resolved from `focusedWorkspaceID` — nil when unfocused OR when the id is
    /// stale (its workspace no longer exists). The single id→workspace lookup the tree filter and the
    /// bottom-bar focus pill both read, so they can't drift.
    public var focusedWorkspace: Workspace? {
        guard let focusedWorkspaceID else { return nil }
        return workspaces.first(where: { $0.id == focusedWorkspaceID })
    }

    /// The workspaces the sidebar tree should render: just the focused workspace when `focusedWorkspaceID`
    /// is set AND that workspace still exists, else all workspaces. The source of truth the tree filters
    /// on; a stale focus id (its workspace gone) falls back to the full tree.
    public var visibleWorkspaces: [Workspace] {
        guard let focused = focusedWorkspace else { return workspaces }
        return [focused]
    }

    /// Sets (or clears) a session's flag — the durable flagged working-set membership the flat sidebar
    /// view projects. Persists the change. Clean no-op (no write) for an unknown id or when the flag is
    /// already in the requested state, so the delta-computed control/menu callers stay idempotent.
    public func setFlag(_ on: Bool, forSession id: UUID) {
        guard let session = session(withID: id), session.flagged != on else { return }
        session.flagged = on
        save()
    }

    /// Sets (or clears) a session's background watermark and persists it. Clean no-op (no write) for an
    /// unknown id or when the spec is unchanged, so a repeated `session.background` set is idempotent.
    /// Returns whether the spec actually CHANGED, so the app target can gate the (retained, teardown-only-
    /// freed) per-surface config apply on a real change — without it, a scripted set-loop keeps appending
    /// owned configs. The app target applies it to the session's surface(s) after this returns (the
    /// host-free store owns only the spec; the C-boundary apply lives in `ControlServer`/`GhosttySurfaceView`).
    @discardableResult
    public func setBackgroundWatermark(_ watermark: BackgroundWatermark?, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), session.backgroundWatermark != watermark else { return false }
        let previous = session.backgroundWatermark
        session.backgroundWatermark = watermark
        // a `.text` watermark owns a rendered `<id>.png`; switching to anything that isn't `.text` (an
        // image, or nil) leaves it id-keyed but unreferenced, so drop it here. `clear`/teardown also sweep
        // the same id-keyed file, so this is just the eager reclaim for the text→image/nil transition.
        if previous?.kind == .text, watermark?.kind != .text {
            WatermarkStorage.removeRenderedText(sessionID: id)
        }
        save()
        return true
    }

    /// Unflags every session across all workspaces in one `save()`. No-ops (no write) when nothing is
    /// flagged. Backs the Clear Flagged action and the `session.flag clear` control mode.
    public func clearFlags() {
        var changed = false
        for workspace in workspaces {
            for session in workspace.sessions where session.flagged {
                session.flagged = false
                changed = true
            }
        }
        if changed { save() }
    }

    /// The flagged sessions across all workspaces in tree order (`workspaces.flatMap(\.sessions)` filtered
    /// by `flagged`). A pure derived projection — the flat sidebar view renders this directly.
    public var flaggedSessions: [Session] {
        workspaces.flatMap(\.sessions).filter(\.flagged)
    }

    /// The session set navigation operates over — the VISIBLE/FILTERED set, not the whole tree: the
    /// flagged sessions in `.flagged` sidebar mode, the focused workspace's sessions when a workspace
    /// is focused, else all sessions. Computed live (`visibleWorkspaces` already collapses to the
    /// focused workspace, or the full tree when unfocused / the focus id is stale), so clearing the
    /// flag/focus naturally restores the full set. Backs `navigateSession` (and via it `session.go`,
    /// attention-nav), the Ctrl-Tab MRU candidate set, AND the ⌃P session palette (`AppActions.
    /// paletteSessions`), so all follow the same filter as the visible sidebar.
    public var navigableSessions: [Session] {
        sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)
    }

    /// The window-wide non-idle sessions, the single source of truth for the titlebar attention icon
    /// and the `.attention` palette. Spans ALL workspaces (`workspaces.flatMap(\.sessions)`) and
    /// deliberately IGNORES the focus/flagged sidebar filter (unlike `navigableSessions`) — the point
    /// is window-wide visibility even when the sidebar is hidden. Sorted by `attentionRank` ascending
    /// (blocked → active → completed) then `statusChangedAt` DESCENDING (newest change first; a nil
    /// stamp sorts last within its rank group).
    public var attentionSessions: [Session] {
        workspaces.flatMap(\.sessions)
            .filter { $0.agentIndicator.status != .idle }
            .sorted { lhs, rhs in
                let lrank = lhs.agentIndicator.status.attentionRank
                let rrank = rhs.agentIndicator.status.attentionRank
                if lrank != rrank { return lrank < rrank }
                switch (lhs.statusChangedAt, rhs.statusChangedAt) {
                case let (l?, r?): return l > r // newest change first within the rank group
                case (_?, nil): return true     // a stamped session sorts before an unstamped one
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
    }

    // MARK: - Persistence

    /// Builds a `Snapshot` value of the current tree. Each session captures its
    /// live `currentCwd` (or `initialCwd` if no PWD report has arrived). Runs on
    /// `@MainActor`; the resulting value is `Sendable` and safe to hand to a writer.
    public func snapshot() -> Snapshot {
        let workspaceSnapshots = workspaces.map { workspace in
            WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: workspace.sessions.map { session in
                SessionSnapshot(id: session.id, customName: session.customName, cwd: session.currentCwd ?? session.initialCwd,
                                isSplit: session.isSplit, fontSize: session.fontSize,
                                splitCwd: session.splitCwd ?? session.initialSplitCwd, splitRatio: session.splitRatio,
                                flagged: session.flagged,
                                foregroundCommand: session.foregroundCommand,
                                splitForegroundCommand: session.splitForegroundCommand,
                                initialCommand: session.initialCommand,
                                backgroundWatermark: session.backgroundWatermark)
            })
        }
        return Snapshot(selectedSessionID: selectedSessionID, workspaces: workspaceSnapshots,
                        sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible, sidebarMode: sidebarMode,
                        focusedWorkspaceID: focusedWorkspaceID)
    }

    /// Rebuilds the tree from a snapshot: fresh `Session`s (surfaces and shells
    /// spawn lazily on first display) keyed by the persisted ids so the restored
    /// `selectedSessionID` still resolves. Replaces the current state wholesale.
    ///
    /// Deliberately does NOT call `save()`: it loads what was just read from disk,
    /// so re-persisting it would be a pointless write (and the only mutator that
    /// skips `save()` for that reason). If the persisted `selectedSessionID` points
    /// at a session that no longer exists, it is cleared to keep selection valid.
    public func restore(from snapshot: Snapshot) {
        workspaces = snapshot.workspaces.map { workspaceSnapshot in
            let sessions = workspaceSnapshot.sessions.map { sessionSnapshot -> Session in
                let session = Session(id: sessionSnapshot.id, initialCwd: sessionSnapshot.cwd, customName: sessionSnapshot.customName)
                session.isSplit = sessionSnapshot.isSplit ?? false
                session.hasSplit = session.isSplit
                session.fontSize = sessionSnapshot.fontSize
                session.initialSplitCwd = sessionSnapshot.splitCwd
                // clamp on restore (like sidebarWidth) so a corrupt snapshot can't feed an out-of-range
                // fraction into NSSplitView.setPosition; nil stays nil (the even default).
                session.splitRatio = sessionSnapshot.splitRatio.map { min(AppStore.splitRatioMax, max(AppStore.splitRatioMin, $0)) }
                session.flagged = sessionSnapshot.flagged ?? false
                session.foregroundCommand = sessionSnapshot.foregroundCommand
                session.splitForegroundCommand = sessionSnapshot.splitForegroundCommand
                session.initialCommand = sessionSnapshot.initialCommand
                session.wasRestored = true
                session.backgroundWatermark = sessionSnapshot.backgroundWatermark
                return session
            }
            return Workspace(id: workspaceSnapshot.id, name: workspaceSnapshot.name, sessions: sessions)
        }
        // clamp on restore (not just nil-default) so a corrupt or hand-edited snapshot can't drive an
        // out-of-range frame width; the drag path clamps to the same bounds.
        sidebarWidth = min(AppStore.sidebarWidthMax, max(AppStore.sidebarWidthMin, snapshot.sidebarWidth ?? AppStore.sidebarWidthDefault))
        sidebarVisible = snapshot.sidebarVisible ?? true
        sidebarMode = snapshot.sidebarMode ?? .tree
        // a stale focus id (its workspace not in the restored tree) is harmless — `visibleWorkspaces`
        // falls back to the full tree — so restore it verbatim; nil stays unfocused.
        focusedWorkspaceID = snapshot.focusedWorkspaceID
        if let id = snapshot.selectedSessionID, session(withID: id) == nil {
            selectedSessionID = nil
        } else {
            selectedSessionID = snapshot.selectedSessionID
        }
        sessionRecency = RecencyStack<UUID>()
        recordRecency()
    }

    /// Persists the current state eagerly. Called after every structural mutation and on
    /// terminate. Cancels any pending debounced save first, so a `save()` (incl. the
    /// quit-flush) always writes the latest snapshot and a stale scheduled write can't
    /// fire afterward. A write failure is logged and swallowed — a transient disk error
    /// must not bring down the model.
    public func save() {
        saveDebouncer.cancel()
        do {
            try persistence.save(snapshot())
        } catch {
            log("save failed: \(error)")
        }
    }

    /// Debounces a `save()` ~0.3 s out, coalescing the rapid selection/font writes. Used only by
    /// `selectSession`/`setFontSize`; structural mutations call `save()` immediately. A `save()`
    /// (or the quit-flush) cancels the pending schedule, so the latest state is always captured.
    private func scheduleSave() {
        saveDebouncer.schedule(after: AppStore.saveDebounceInterval) { [weak self] in
            self?.save()
        }
    }

    /// Drops any pending debounced save WITHOUT writing — unlike `save()`, which cancels then writes.
    /// Used when the owning window is being deleted (`WindowLibrary.removeWindow`): the per-window file
    /// is about to be removed, so a save scheduled by a just-before-delete selectSession/setFontSize
    /// must be dropped rather than flushed, else it would fire after the file is deleted and re-create
    /// it as an orphan.
    public func cancelPendingSave() {
        saveDebouncer.cancel()
    }

    private func log(_ message: @autoclosure () -> String) {
        NSLog("agterm: %@", message())
    }

    // MARK: - Derivation

    /// The workspace that owns the given session, if any.
    public func workspace(forSession sessionID: UUID) -> Workspace? {
        guard let location = location(ofSession: sessionID) else { return nil }
        return workspaces[location.workspaceIndex]
    }

    /// The session with the given id across all workspaces, if any.
    public func session(withID sessionID: UUID) -> Session? {
        for workspace in workspaces {
            if let session = workspace.sessions.first(where: { $0.id == sessionID }) { return session }
        }
        return nil
    }

    private func location(ofSession sessionID: UUID) -> (workspaceIndex: Int, sessionIndex: Int)? {
        for (wi, workspace) in workspaces.enumerated() {
            if let si = workspace.sessions.firstIndex(where: { $0.id == sessionID }) { return (wi, si) }
        }
        return nil
    }

    /// Picks the next selection after removing the session at `location`. Prefers
    /// the session that shifted into the removed slot, then the previous one in
    /// that workspace, then the first session of any remaining workspace.
    private func reselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID? {
        let sessions = workspaces[location.workspaceIndex].sessions
        if location.sessionIndex < sessions.count { return sessions[location.sessionIndex].id }
        if location.sessionIndex > 0 { return sessions[location.sessionIndex - 1].id }
        for workspace in workspaces {
            if let first = workspace.sessions.first { return first.id }
        }
        return nil
    }
}
