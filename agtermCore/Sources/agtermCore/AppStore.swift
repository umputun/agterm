import Foundation
import Observation

/// A relative step through the flattened session list for keyboard navigation.
/// `next`/`previous` step one and wrap around at the ends, `first`/`last` jump to a tree end.
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

    /// Transient sidebar multi-selection. Not persisted: it is UI command state, while
    /// `selectedSessionID` remains the durable active terminal target.
    var sidebarSelectionRaw: [UUID] = []

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
    /// switcher, not by any SwiftUI view. Persisted in the snapshot so the switcher's order
    /// survives a relaunch.
    @ObservationIgnored public private(set) var sessionRecency = RecencyStack<UUID>()

    /// The latest session/workspace close that can still be undone. The hidden sessions/workspaces live
    /// in `pendingCloseRecords`; this observed summary is the host-free state the app target presents.
    public var pendingCloseSummary: PendingCloseSummary?

    @ObservationIgnored var pendingCloseRecords: [UUID: PendingCloseRecord] = [:]
    @ObservationIgnored var pendingCloseOrder: [UUID] = []
    @ObservationIgnored var pendingCloseTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored private let persistence: PersistenceStore
    @ObservationIgnored let recentClosedStore: RecentClosedStore?
    @ObservationIgnored var recentClosedDidChange: (() -> Void)?

    /// Coalesces the high-frequency selection/font saves: a click-storm or a font ramp schedules one
    /// write ~0.3 s after the burst settles instead of hitting disk per event. `save()` cancels any
    /// pending scheduled save, so the quit-flush (`saveAllOpen()` → `save()`) still captures the latest.
    @ObservationIgnored private let saveDebouncer = Debouncer()

    /// The quiet window before a scheduled (selection/font) save writes to disk.
    private static let saveDebounceInterval: TimeInterval = 0.3

    /// The idle timeout after which the window auto-jumps its selection to the oldest blocked session, or
    /// nil when auto-follow is off (the default). Set by the Settings fan-out; read by `noteUserActivity`
    /// (to arm the debouncer) and the control tree. `@ObservationIgnored`: read imperatively, no view reacts.
    @ObservationIgnored var autoFollowTimeout: TimeInterval?

    /// Whether auto-follow suppresses the jump while the current session is `active` (the opt-in "don't
    /// auto-follow away from a running session" toggle). Default false. `@ObservationIgnored`.
    @ObservationIgnored var autoFollowStayOnActive = false

    /// The last time the user interacted with this window (a keystroke or a manual selection), stamped
    /// unconditionally by `noteUserActivity` so the idle metric is independent of the feature being on.
    /// nil until the first interaction. `@ObservationIgnored`: read imperatively (`idleMs`, the control
    /// tree) and stamped at high frequency, so no view should react to it.
    @ObservationIgnored var lastActivityAt: Date?

    /// Coalesces user activity into a single deferred `autoFollowFire`: each `noteUserActivity` reschedules,
    /// so the fire runs only once the user has been idle for `autoFollowTimeout`. `internal` (NOT private)
    /// so `@testable` tests can drive its `flush()` seam.
    @ObservationIgnored let autoFollowDebouncer = Debouncer()

    /// Coalesces the deferred re-arms the auto-follow status observer schedules into one per runloop turn,
    /// mirroring `DockBadgeController.scheduleRefresh`: a single agent-status flip can fire several live
    /// observation trackers at once, so this collapses them to one re-arm (and one re-registration).
    /// `internal` only so the `AppStore+AutoFollow` extension (a separate file) can reach it.
    @ObservationIgnored var autoFollowRearmScheduled = false

    /// Non-zero while a non-terminal editor or transient overlay in this window owns first responder — the
    /// sidebar inline-rename field or an open command palette. `autoFollowFire` no-ops while this is
    /// positive, so an armed idle jump can't yank the selection out from under an in-progress rename or
    /// reshuffle a palette's action target. A COUNT (not a bool) so the several independent suppressors can
    /// overlap safely: each brackets itself with `suppressAutoFollow`/`resumeAutoFollow`, and a suppressor
    /// lifting while another still holds keeps the jump suppressed. The app owns the first-responder
    /// knowledge; the store just gates on the count. `internal` so the `AppStore+AutoFollow` extension can
    /// read it; mutated only through the two public methods so the app target (a separate module) can't
    /// desync it. `@ObservationIgnored`: read imperatively at fire time, no view reacts.
    @ObservationIgnored var autoFollowSuppressionCount = 0

    public init(workspaces: [Workspace] = [], selectedSessionID: UUID? = nil,
                persistence: PersistenceStore = PersistenceStore(),
                recentClosedStore: RecentClosedStore? = nil,
                recentClosedDidChange: (() -> Void)? = nil) {
        self.workspaces = workspaces
        self.selectedSessionID = selectedSessionID
        self.persistence = persistence
        self.recentClosedStore = recentClosedStore
        self.recentClosedDidChange = recentClosedDidChange
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

    /// Projects this store's workspace/session model into the control-channel `tree` payload. Foreground
    /// command lookup is supplied by the host because live process inspection is platform-specific.
    public func controlTree(foreground: (Session) -> [String]? = { _ in nil },
                            splitForeground: (Session) -> [String]? = { _ in nil },
                            fontSize: (Session) -> Double? = { _ in nil },
                            splitFontSize: (Session) -> Double? = { _ in nil },
                            scratchFontSize: (Session) -> Double? = { _ in nil },
                            quickVisible: () -> Bool? = { nil },
                            zoomedSurface: () -> String? = { nil },
                            dashboardMembers: () -> [String]? = { nil },
                            dashboardHighlighted: () -> String? = { nil },
                            dashboardFontSize: () -> Double? = { nil },
                            dashboardFontMode: () -> String? = { nil }) -> ControlTree {
        let activeID = selectedSessionID
        let activeWorkspaceID = activeID.flatMap { workspace(forSession: $0)?.id }
        let nodes = workspaces.map { workspace in
            let sessions = workspace.sessions.map { session in
                let idle = session.agentIndicator.status == .idle
                let status = idle ? nil : session.agentIndicator.status.rawValue
                let statusPane = idle ? nil : session.agentIndicator.statusPane?.rawValue
                let surfaces = TerminalZoomSurface.allCases.compactMap { surface -> ControlSurfaceNode? in
                    guard surface.isAvailable(in: session) else { return nil }
                    let id = TerminalSurfaceID(sessionID: session.id, surface: surface).rawValue
                    return ControlSurfaceNode(id: id, kind: surface.rawValue,
                                              active: surface.isActive(in: session),
                                              visible: surface.isVisible(in: session))
                }
                return ControlSessionNode(id: session.id.uuidString, name: session.displayName,
                                          cwd: session.effectiveCwd, title: session.oscTitle,
                                          active: session.id == activeID,
                                          split: session.isSplit,
                                          splitRatio: session.hasSplit ? session.splitRatio : nil,
                                          splitFocused: session.hasSplit ? session.splitFocused : nil,
                                          overlay: session.overlayActive,
                                          overlaySizePercent: session.overlayActive ? session.overlaySizePercent : nil,
                                          scratch: session.scratchActive, flagged: session.flagged,
                                          foreground: foreground(session),
                                          splitForeground: splitForeground(session), status: status,
                                          statusPane: statusPane,
                                          statusBlink: idle ? nil : (session.agentIndicator.blink ? true : nil),
                                          statusColor: idle ? nil : session.agentIndicator.color,
                                          background: session.backgroundWatermark,
                                          unseen: session.unseenCount > 0 ? session.unseenCount : nil,
                                          fontSize: fontSize(session),
                                          splitFontSize: splitFontSize(session),
                                          scratchFontSize: scratchFontSize(session),
                                          surfaces: surfaces)
            }
            return ControlWorkspaceNode(id: workspace.id.uuidString, name: workspace.name,
                                        active: workspace.id == activeWorkspaceID,
                                        focused: workspace.id == focusedWorkspaceID ? true : nil,
                                        sessions: sessions)
        }
        return ControlTree(workspaces: nodes, idleMs: idleMs(), autoFollowMs: autoFollowMs,
                           sidebarVisible: sidebarVisible, sidebarMode: sidebarMode.rawValue,
                           quickVisible: quickVisible(), zoomedSurface: zoomedSurface(),
                           dashboardMembers: dashboardMembers(),
                           dashboardHighlighted: dashboardHighlighted(),
                           dashboardFontSize: dashboardFontSize(),
                           dashboardFontMode: dashboardFontMode())
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

    /// Creates a session in the given workspace and selects it. An optional `name` seeds the session's
    /// `customName` (trimmed; blank clears it to the auto basename, matching `renameSession`). With `at`
    /// nil the session is appended (the default); with `at` set it is inserted at the clamped index
    /// (`0...count`), backing the control `session.new --after`/`--before` placement. Returns nil if no
    /// workspace matches.
    @discardableResult
    public func addSession(toWorkspace workspaceID: UUID, cwd: String, command: String? = nil,
                           name: String? = nil, at index: Int? = nil) -> Session? {
        guard let wsIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let session = Session(initialCwd: cwd, customName: name?.trimmedOrNil)
        session.initialCommand = command
        if let index {
            let destination = max(0, min(index, workspaces[wsIndex].sessions.count))
            workspaces[wsIndex].sessions.insert(session, at: destination)
        } else {
            workspaces[wsIndex].sessions.append(session)
        }
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
    public func selectSession(_ sessionID: UUID?, sidebarSelection selectionIDs: [UUID]? = nil) {
        if let sessionID, session(withID: sessionID) == nil { return }
        let previous = selectedSessionID
        selectedSessionID = sessionID
        if let selectionIDs {
            setSidebarSelection(selectionIDs)
        } else {
            replaceSidebarSelection(with: sessionID)
        }
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
    func autoUnfocusIfOutsideFocus(_ sessionID: UUID?) {
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
        var indicator = indicator
        // normalize a `.right` tag to `.left` when the session has NO split. A promoted survivor's
        // shell keeps its baked `AGTERM_PANE=right`, so the agent-status hook re-emits `--pane right` after
        // promotion even though there is no right pane — left unnormalized that re-creates the
        // `split:false` + `statusPane:"right"` contradiction the round-3 re-tag fixed, and the sole
        // (`.left`-role-aware) pane could never keystroke-clear it. A hidden-but-LIVE split keeps
        // `hasSplit`, so `.right` stays valid there. `.left`/`.scratch` are untouched.
        // gated on `hasSplit`, NOT `splitSurface == nil`: `toggleSplit`/restore set `hasSplit`
        // synchronously while the deck creates `splitSurface` a render pass later, so a scripted
        // `session.split` + immediate `session.status --pane right` lands in that realization window —
        // there `.right` is the correct forward tag and must NOT be rewritten. `splitSurface != nil`
        // implies `hasSplit` (only `closeSplit`/`closePrimaryPane` clear it, tearing the surface down
        // with it), so `!hasSplit` still covers every genuinely splitless session.
        if indicator.statusPane == .right, !session.hasSplit {
            indicator.statusPane = .left
        }
        session.agentIndicator = indicator
        session.statusChangedAt = indicator.status == .idle ? nil : Date()
    }

    /// Pushes the current selection to the front of the recency stack (the Ctrl-Tab order).
    /// No-op when nothing is selected.
    func recordRecency() {
        if let selectedSessionID { sessionRecency.push(selectedSessionID) }
    }

    func removeFromRecency(_ id: UUID) {
        sessionRecency.remove(id)
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
        let workspace = workspaces[location.workspaceIndex]
        let removed = workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex)
        recordRecentClosedSession(removed, workspaceID: workspace.id, workspaceName: workspace.name,
                                  workspaceIndex: location.workspaceIndex, sessionIndex: location.sessionIndex)
        removed.surface?.teardown()
        removed.splitSurface?.teardown()
        removed.overlaySurface?.teardown()
        removed.scratchSurface?.teardown()
        WatermarkStorage.removeRenderedText(sessionID: sessionID) // drop any rendered .text PNG; the session is gone
        sessionRecency.remove(sessionID)
        if wasActive {
            selectedSessionID = reselectionTarget(after: location)
            replaceSidebarSelection(with: selectedSessionID)
            autoUnfocusIfOutsideFocus(selectedSessionID) // the neighbor may live outside the focused workspace
            recordRecency()
        } else {
            pruneSidebarSelection()
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
        let workspace = workspaces[index]
        let removingActive = selectedSessionID.map { id in workspace.sessions.contains { $0.id == id } } ?? false
        recordRecentClosedWorkspace(workspace, selectedSessionID: removingActive ? selectedSessionID : nil)
        for session in workspace.sessions {
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
            replaceSidebarSelection(with: selectedSessionID)
            autoUnfocusIfOutsideFocus(selectedSessionID) // the reselected session may live outside the focused workspace
            recordRecency()
        } else {
            pruneSidebarSelection()
        }
        save()
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
        pruneSidebarSelection()
        save()
    }

    /// Moves selected sessions in their current tree order. With `index == nil`, a multi-session context
    /// move appends cross-workspace sessions and leaves sessions already in the target in place; a
    /// one-session call matches `moveSession` and appends even within that workspace. With an explicit
    /// `index`, this is a drag drop: remove every dragged session first, then insert the dragged block at
    /// that post-removal target index. Returns the number of sessions actually moved.
    @discardableResult
    public func moveSessions(_ sessionIDs: [UUID], toWorkspace targetID: UUID, at index: Int? = nil) -> Int {
        guard workspaces.contains(where: { $0.id == targetID }) else { return 0 }
        var movingIDs = orderedSessionIDs(matching: Set(sessionIDs))
        // A one-element batch is wire-equivalent to `moveSession`: even within the destination
        // workspace it moves to the end. Multi-selection context moves leave existing members in place.
        if index == nil, movingIDs.count > 1 {
            movingIDs = movingIDs.filter { workspace(forSession: $0)?.id != targetID }
        }
        guard !movingIDs.isEmpty else { return 0 }

        var moving: [Session] = []
        for id in movingIDs {
            guard let location = location(ofSession: id) else { continue }
            moving.append(workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex))
        }
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }), !moving.isEmpty else {
            pruneSidebarSelection()
            return 0
        }
        let destination = max(0, min(index ?? workspaces[targetIndex].sessions.count,
                                     workspaces[targetIndex].sessions.count))
        workspaces[targetIndex].sessions.insert(contentsOf: moving, at: destination)
        if let selectedSessionID, movingIDs.contains(selectedSessionID) { autoUnfocusIfOutsideFocus(selectedSessionID) }
        pruneSidebarSelection()
        save()
        return moving.count
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
    /// in the sidebar's visual order. `next`/`previous` move one and WRAP at the ends WITHIN the filtered
    /// set (`next` on the last lands on the first, `previous` on the first lands on the last, never
    /// leaking across the filter — matching the cyclic attention-nav below); `first`/`last` jump to the
    /// ends of the filtered list. With no/invalid current selection, `next`/`previous` land on its first
    /// session. No-op when the filtered list is empty. Routes through `selectSession`, inheriting recency,
    /// badge clearing, persistence, and workspace derivation. Because the targets are always in-set, nav
    /// never triggers `autoUnfocusIfOutsideFocus` — that stays the safety net for an explicit cross-set
    /// select.
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
                target = ids[((i + step) % ids.count + ids.count) % ids.count] // cycle within the filtered set
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

    /// Sets this window's sidebar visibility and persists it. Clean no-op (no write) when unchanged, so
    /// menu, toolbar, palette, and control callers can delta-compute their desired state without
    /// duplicating the persistence gate. `sidebarVisible` is per-window state saved in this store's
    /// snapshot.
    public func setSidebarVisible(_ visible: Bool) {
        guard sidebarVisible != visible else { return }
        sidebarVisible = visible
        save()
        // refresh the app-target ControlServer's window.list cache: a GUI-only toggle isn't a control
        // command, so without this the cached sidebarVisible would lag until the next command.
        NotificationCenter.default.post(name: .agtermSidebarVisibilityChanged, object: nil)
    }

    /// Flips this window's sidebar visibility and persists the new state.
    public func toggleSidebarVisible() {
        setSidebarVisible(!sidebarVisible)
    }

    /// Sets the sidebar mode and persists it. Clean no-op (no write) when the mode is unchanged, so the
    /// delta-computed control/menu callers stay idempotent.
    public func setSidebarMode(_ mode: SidebarMode) {
        guard sidebarMode != mode else { return }
        sidebarMode = mode
        pruneSidebarSelection()
        save()
    }

    /// Sets (or clears) the focused workspace and persists it. Clean no-op (no write) when unchanged, so
    /// the delta-computed control/menu callers stay idempotent. Passing nil unfocuses.
    public func setFocusedWorkspace(_ id: UUID?) {
        guard focusedWorkspaceID != id else { return }
        focusedWorkspaceID = id
        pruneSidebarSelection()
        save()
    }

    /// Sets one workspace's expand/collapse state and persists it. Clean no-op (no write) for an unknown id
    /// or when unchanged. The sidebar calls this for a GENUINE per-row user toggle only (a row click or the
    /// disclosure triangle), never for a programmatic reveal — so a deliberate collapse survives a later
    /// reveal of a session inside the workspace, and toggling one workspace never touches another's saved
    /// state (unlike `setWorkspacesExpanded`, which rewrites the whole tree).
    public func setWorkspaceExpanded(_ id: UUID, expanded: Bool) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces[index].isExpanded != expanded else { return }
        workspaces[index].isExpanded = expanded
        save()
    }

    /// Marks each workspace expanded iff its id is in `expandedIDs` and persists the collapse state so it
    /// survives a relaunch. One `save()` for the whole diff; a clean no-op (no write) when nothing changed.
    /// Backs the deliberate all-workspace commands (Expand Workspaces / Collapse Workspaces), which set
    /// every workspace at once; per-row toggles use `setWorkspaceExpanded` instead.
    public func setWorkspacesExpanded(_ expandedIDs: Set<UUID>) {
        var changed = false
        for index in workspaces.indices {
            let expanded = expandedIDs.contains(workspaces[index].id)
            if workspaces[index].isExpanded != expanded {
                workspaces[index].isExpanded = expanded
                changed = true
            }
        }
        if changed { save() }
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
        pruneSidebarSelection()
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
            save()
        }
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
        if changed {
            pruneSidebarSelection()
            save()
        }
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
    /// flag/focus naturally restores the full set. `navigateSession` next/prev WRAP within this set (an
    /// end lands on the opposite end, never leaking across the filter). Backs `navigateSession` (and via
    /// it `session.go`, attention-nav), the Ctrl-Tab MRU candidate set, AND the ⌃P session palette
    /// (`AppActions.paletteSessions`), so all follow the same filter as the visible sidebar.
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
            let sessions = workspace.sessions.map(sessionSnapshot)
            // only a collapsed workspace writes the flag; an expanded one omits it (nil) so an all-expanded
            // tree serializes identically to a legacy snapshot.
            return WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: sessions,
                                     collapsed: workspace.isExpanded ? nil : true)
        }
        return Snapshot(selectedSessionID: selectedSessionID, workspaces: workspaceSnapshots,
                        sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible, sidebarMode: sidebarMode,
                        focusedWorkspaceID: focusedWorkspaceID, sessionRecency: sessionRecency.items)
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
        // fold workspaces sharing an id into the first occurrence, and keep only the first snapshot of any
        // repeated session id, wherever it sits: a file written by a build that could duplicate either
        // stays unreachable past the first match otherwise, and re-saves the corruption.
        var seenSessionIDs: Set<UUID> = []
        workspaces = snapshot.workspaces.reduce(into: [Workspace]()) { restored, workspaceSnapshot in
            let sessions = workspaceSnapshot.sessions
                .filter { seenSessionIDs.insert($0.id).inserted }
                .map(session(from:))
            if let existing = restored.firstIndex(where: { $0.id == workspaceSnapshot.id }) {
                restored[existing].sessions.append(contentsOf: sessions)
                return
            }
            // absent/nil collapsed → expanded (back-compat with snapshots written before the field existed).
            restored.append(Workspace(id: workspaceSnapshot.id, name: workspaceSnapshot.name, sessions: sessions,
                                      isExpanded: !(workspaceSnapshot.collapsed ?? false)))
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
        replaceSidebarSelection(with: selectedSessionID)
        // re-seed the Ctrl-Tab order from the persisted list (dropping ids not in the restored
        // tree) so the switcher works right after relaunch; the restored selection floats to the
        // front, keeping the "previous session" slot truthful.
        let restoredIDs = Set(workspaces.flatMap(\.sessions).map(\.id))
        sessionRecency = RecencyStack(items: (snapshot.sessionRecency ?? []).filter { restoredIDs.contains($0) })
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

    func location(ofSession sessionID: UUID) -> (workspaceIndex: Int, sessionIndex: Int)? {
        for (wi, workspace) in workspaces.enumerated() {
            if let si = workspace.sessions.firstIndex(where: { $0.id == sessionID }) { return (wi, si) }
        }
        return nil
    }

    private func orderedSessionIDs(matching ids: Set<UUID>) -> [UUID] {
        workspaces.flatMap(\.sessions).map(\.id).filter { ids.contains($0) }
    }

    /// Picks the next selection after removing the session at `location`. Prefers
    /// the session that shifted into the removed slot, then the previous one in
    /// that workspace, then the first session of any remaining workspace.
    func reselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID? {
        let sessions = workspaces[location.workspaceIndex].sessions
        if location.sessionIndex < sessions.count { return sessions[location.sessionIndex].id }
        if location.sessionIndex > 0, !sessions.isEmpty {
            return sessions[min(location.sessionIndex - 1, sessions.count - 1)].id
        }
        for workspace in workspaces {
            if let first = workspace.sessions.first { return first.id }
        }
        return nil
    }

    func sessionSnapshot(_ session: Session) -> SessionSnapshot {
        SessionSnapshot(id: session.id, customName: session.customName, cwd: session.currentCwd ?? session.initialCwd,
                        isSplit: session.isSplit, fontSize: session.fontSize,
                        splitCwd: session.splitCwd ?? session.initialSplitCwd, splitRatio: session.splitRatio,
                        flagged: session.flagged,
                        foregroundCommand: session.foregroundCommand,
                        splitForegroundCommand: session.splitForegroundCommand,
                        initialCommand: session.initialCommand,
                        backgroundWatermark: session.backgroundWatermark)
    }

    func workspaceSnapshot(_ workspace: Workspace) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: workspace.sessions.map(sessionSnapshot),
                          collapsed: workspace.isExpanded ? nil : true)
    }

    func session(from snapshot: SessionSnapshot) -> Session {
        let session = Session(id: snapshot.id, initialCwd: snapshot.cwd, customName: snapshot.customName)
        session.isSplit = snapshot.isSplit ?? false
        session.hasSplit = session.isSplit
        session.fontSize = snapshot.fontSize
        session.initialSplitCwd = snapshot.splitCwd
        session.splitRatio = snapshot.splitRatio.map { min(AppStore.splitRatioMax, max(AppStore.splitRatioMin, $0)) }
        session.flagged = snapshot.flagged ?? false
        session.foregroundCommand = snapshot.foregroundCommand
        session.splitForegroundCommand = snapshot.splitForegroundCommand
        session.initialCommand = snapshot.initialCommand
        session.wasRestored = true
        session.backgroundWatermark = snapshot.backgroundWatermark
        return session
    }

    func workspace(from snapshot: WorkspaceSnapshot) -> Workspace {
        Workspace(id: snapshot.id, name: snapshot.name, sessions: snapshot.sessions.map(session(from:)),
                  isExpanded: !(snapshot.collapsed ?? false))
    }

}
