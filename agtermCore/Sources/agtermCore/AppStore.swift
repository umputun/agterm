import Foundation
import Observation

/// A relative step through the flattened session list for keyboard navigation. `next`/`previous` step one
/// and wrap, `first`/`last` jump to a tree end, `nextAttention`/`previousAttention` step (wrapping) through
/// only the sessions needing attention — status `blocked` or `completed`.
public enum SessionNavigation: Sendable { case next, previous, first, last, nextAttention, previousAttention }

extension SessionNavigation {
    /// Maps a control-channel direction string to a case, nil for an unknown one. Both `prev` (the CLI's
    /// spelling) and `previous` are accepted.
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

/// The whole app state: the workspace tree and the current selection. `@Observable @MainActor` so views
/// observe mutations and all model access is main-actor isolated (implicitly `Sendable` via isolation).
/// Selection is one `Session.ID?` — workspace rows are non-selectable headers, so the workspace is derived.
@Observable
@MainActor
public final class AppStore {
    public var workspaces: [Workspace]
    /// A CHANGE here drops `freshWorkspaceID`: close, workspace removal, pending-close undo and Reopen
    /// Closed Item all reselect by assigning directly, so centralizing it is what keeps a fresh workspace
    /// from outliving a selection made outside `selectSession`. A same-value write must not, because
    /// reselecting the already-active session is what `navigateSession` with one visible session and
    /// `overlay open --follow` both do, and neither moves the user. `restore(from:)` clears explicitly —
    /// it reloads state rather than selecting.
    public var selectedSessionID: UUID? {
        didSet {
            if selectedSessionID != oldValue { freshWorkspaceID = nil }
        }
    }

    /// Transient sidebar multi-selection, not persisted — `selectedSessionID` stays the durable active target.
    var sidebarSelectionRaw: [UUID] = []

    /// Whether this window's sidebar is shown; per-window state persisted in `Snapshot`. The custom split
    /// owns visibility, so toolbar, View menu, palette and the `sidebar` command all flip this one flag.
    public var sidebarVisible = true

    /// Which view this window's sidebar renders: the tree or the flat flagged working set. Per-window state
    /// in `Snapshot`, flipped via `setSidebarMode(_:)` (bottom bar, View menu, palette, `sidebar.mode`).
    public var sidebarMode: SidebarMode = .tree

    /// The workspaces marked for the sidebar focus filter — the working set the tree renders when
    /// `focusEnabled` is on (see `visibleWorkspaces`). Per-window state in `Snapshot`; orthogonal to
    /// `sidebarMode` (flagged mode ignores focus). Mutated via `setFocusedWorkspace(_:)`/
    /// `setFocusMembership(_:member:)` by the row menu, View menu, palette and `workspace.focus`; a member is
    /// pruned when its workspace is removed. `internal(set)`, so no app-target line breaks the invariant below.
    public internal(set) var focusedWorkspaceIDs: Set<UUID> = []

    /// Whether the focus filter applies, so a hand-curated set survives being switched off. Per-window state
    /// in `Snapshot`, `internal(set)` like the set above. Enabled with an EMPTY set is unrepresentable, which
    /// makes the FILTER-ON half of the control row-visibility read-back (`ControlWorkspaceNode.focused`)
    /// exact — an applied filter always has at least one visible member; the filter-OFF half
    /// (`visibleWorkspaces` returning the whole tree) is outside the invariant. Three guards hold it:
    /// `setFocusEnabled(true)` no-ops on an empty set (matching the bottom-bar toggle, disabled in exactly
    /// that state), `setFocusMembership`/`dropFocusMember` disable as the set empties, and
    /// `restoreFocus(from:)` prunes ids absent from the restored tree, disabling when that empties it. Driven
    /// by the bottom-bar `focus-filter-toggle`, View ▸ Toggle Workspace Filter,
    /// `BuiltinAction.toggleWorkspaceFilter`, and `workspace.filter`.
    public internal(set) var focusEnabled = false

    /// This window's sidebar width in points, persisted in `Snapshot`; drag-driven, clamped to the bounds below.
    public var sidebarWidth: Double = AppStore.sidebarWidthDefault

    /// Default + drag/restore bounds, shared by the divider drag and the `restore()` clamp so they can't drift.
    public static let sidebarWidthDefault: Double = 220
    public static let sidebarWidthMin: Double = 160
    public static let sidebarWidthMax: Double = 560

    /// The persisted split-divider left-pane fraction bounds: live capture skips degenerate extremes outside
    /// this range and `restore()` clamps to it, so the on-disk ratio is always within bounds.
    public static let splitRatioMin: Double = 0.05
    public static let splitRatioMax: Double = 0.95
    /// The even split a never-moved divider renders at (the `HSplitView` default); the base for a relative
    /// `session.resize` while `Session.splitRatio` is nil.
    public static let splitRatioDefault: Double = 0.5

    /// Clamp a left-pane split fraction to `splitRatioMin...splitRatioMax`.
    public static func clampSplitRatio(_ ratio: Double) -> Double {
        min(splitRatioMax, max(splitRatioMin, ratio))
    }

    /// Most-recently-selected session ids, front = current; drives the Ctrl-Tab switcher (`items[1]` is the
    /// previous). `@ObservationIgnored`, read imperatively; persisted so the order survives a relaunch.
    @ObservationIgnored public private(set) var sessionRecency = RecencyStack<UUID>()

    /// The latest undoable session/workspace close; the hidden items live in `pendingCloseRecords`, this
    /// observed summary is the host-free state the app target presents.
    public var pendingCloseSummary: PendingCloseSummary?

    @ObservationIgnored var pendingCloseRecords: [UUID: PendingCloseRecord] = [:]
    @ObservationIgnored var pendingCloseOrder: [UUID] = []
    @ObservationIgnored var pendingCloseTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored private let persistence: PersistenceStore
    @ObservationIgnored let recentClosedStore: RecentClosedStore?
    @ObservationIgnored var recentClosedDidChange: (() -> Void)?
    @ObservationIgnored let controlEventSink: ((ControlEventDraft) -> Void)?
    /// Coalesces the high-frequency selection/font saves: a click-storm or a font ramp writes once after the
    /// burst settles instead of hitting disk per event.
    @ObservationIgnored private let saveDebouncer = Debouncer()

    /// The quiet window before a scheduled (selection/font) save writes to disk.
    private static let saveDebounceInterval: TimeInterval = 0.3

    /// Idle timeout after which the window auto-jumps its selection to the oldest blocked session, nil when
    /// auto-follow is off (the default). Set by the Settings fan-out; read imperatively by `noteUserActivity`
    /// (arming the debouncer) and the control tree, so no view reacts.
    @ObservationIgnored var autoFollowTimeout: TimeInterval?

    /// Whether auto-follow suppresses the jump while the current session is `active` (opt-in, default false).
    @ObservationIgnored var autoFollowStayOnActive = false

    /// The last user interaction with this window (a keystroke or a manual selection), nil until the first.
    /// Stamped unconditionally by `noteUserActivity`, so the idle metric is independent of the feature being
    /// on. Stamped at high frequency and read imperatively, so no view may react to it.
    @ObservationIgnored var lastActivityAt: Date?

    /// Coalesces user activity into one deferred `autoFollowFire`: each `noteUserActivity` reschedules, so it
    /// fires only after `autoFollowTimeout` of idle. `internal`, not private, for the tests' `flush()` seam.
    @ObservationIgnored let autoFollowDebouncer = Debouncer()

    /// Coalesces the auto-follow status observer's deferred re-arms into one re-arm (and re-registration) per
    /// runloop turn, mirroring `DockBadgeController.scheduleRefresh`: one agent-status flip can fire several
    /// live observation trackers at once. `internal` only for the `AppStore+AutoFollow` extension.
    @ObservationIgnored var autoFollowRearmScheduled = false

    /// Non-zero while a non-terminal editor or transient overlay owns first responder (the sidebar rename
    /// field, an open command palette): `autoFollowFire` no-ops while positive, so an armed idle jump can't
    /// yank the selection out of an in-progress rename or reshuffle a palette's action target. A COUNT, not a
    /// bool, so independent suppressors overlap safely — each brackets itself with `suppressAutoFollow`/
    /// `resumeAutoFollow`, and one lifting while another holds keeps the jump suppressed. The app owns the
    /// first-responder knowledge, the store only the count; `internal` for the `AppStore+AutoFollow` extension
    /// and mutated only through the two public methods, so the app target cannot desync it.
    @ObservationIgnored var autoFollowSuppressionCount = 0

    public init(workspaces: [Workspace] = [], selectedSessionID: UUID? = nil,
                persistence: PersistenceStore = PersistenceStore(),
                recentClosedStore: RecentClosedStore? = nil,
                recentClosedDidChange: (() -> Void)? = nil,
                controlEventSink: ((ControlEventDraft) -> Void)? = nil) {
        self.workspaces = workspaces
        self.selectedSessionID = selectedSessionID
        self.persistence = persistence
        self.recentClosedStore = recentClosedStore
        self.recentClosedDidChange = recentClosedDidChange
        self.controlEventSink = controlEventSink
    }

    /// The currently selected session, derived from `selectedSessionID`.
    public var activeSession: Session? {
        guard let selectedSessionID else { return nil }
        return session(withID: selectedSessionID)
    }

    /// The workspace that holds the target without owning the selection: a FOREGROUND create, or a
    /// `selectWorkspace` on an empty one, which has no session to select. Without it a new workspace is never
    /// current (discussion #325): selection does not move on create, so Rename Workspace edited the previous
    /// one and the next new session landed there too. Dropped by a selection CHANGE
    /// (`selectedSessionID`'s observer, so a same-value write keeps it), by `selectWorkspace` naming a
    /// workspace that HAS a session — which a same-value selection alone would not do — by removing the
    /// workspace, by the focus filter hiding it, and by `restore(from:)`. A BACKGROUND create (`revealNewWorkspace: false`)
    /// never sets it, so a script's create cannot steer the GUI's next add.
    private var freshWorkspaceID: UUID?

    /// Drops the fresh-workspace preference when that workspace is the one going away, so an Undo or Reopen
    /// re-inserting the same id cannot revive it. Every removal path calls this; a reorder must not.
    func forgetFreshWorkspace(_ workspaceID: UUID) {
        if freshWorkspaceID == workspaceID { freshWorkspaceID = nil }
    }

    /// Makes `workspaceID` the current one and selects its first session when it has one. Both halves are
    /// needed: the first session may already BE the selection, and a same-value write leaves the target
    /// alone; an empty workspace has nothing to select at all, and reporting success while targeting
    /// somewhere else is what made `workspace.select --target <empty>` a lie. Backs `workspace.select`.
    @discardableResult
    public func selectWorkspace(_ workspaceID: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return false }
        if let first = workspace.sessions.first {
            selectSession(first.id)
            freshWorkspaceID = nil
            return true
        }
        // an empty workspace the filter hides would be a target with no row: reveal it, the same
        // auto-reveal `addWorkspace` performs, so what is current is always on screen. the target itself
        // is live state outside `snapshot()`, so only the widened set is worth a write.
        let marked = focusedWorkspaceIDs
        revealNewFocusMember(workspaceID)
        freshWorkspaceID = workspaceID
        if focusedWorkspaceIDs != marked { save() }
        return true
    }

    /// Drops the target when the focus filter has hidden it, so turning the filter off later cannot make it
    /// current again — hiding it hands targeting back for good. Called from the one focus commit point.
    func forgetHiddenFreshWorkspace() {
        guard let freshWorkspaceID else { return }
        if !visibleWorkspaces.contains(where: { $0.id == freshWorkspaceID }) { self.freshWorkspaceID = nil }
    }

    /// The workspace a new session lands in: a freshly created one, else the selected session's, else the
    /// last (nil when there are none). Drives the bottom bar's add actions, File ▸ New Session / Open
    /// Directory / Rename Workspace, and resolves `active` for control-channel workspace targets.
    public var currentWorkspaceID: UUID? {
        if let freshWorkspaceID, workspaces.contains(where: { $0.id == freshWorkspaceID }) {
            return freshWorkspaceID
        }
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
                            pickPending: () -> String? = { nil },
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
                                          paneOverlays: paneOverlays(session),
                                          scratch: session.scratchActive, flagged: session.flagged,
                                          commandWait: (session.initialCommand != nil && session.commandWait) ? true : nil,
                                          foreground: foreground(session),
                                          splitForeground: splitForeground(session),
                                          // the PERSISTED overrides, not the transient pending payloads, so
                                          // a read after one fired still reports what stays pinned.
                                          restoreCommand: session.restoreCommand,
                                          splitRestoreCommand: session.splitRestoreCommand, status: status,
                                          statusPane: statusPane,
                                          statusBlink: idle ? nil : (session.agentIndicator.blink ? true : nil),
                                          statusColor: idle ? nil : session.agentIndicator.color,
                                          statusShape: idle ? nil : session.agentIndicator.shape?.rawValue,
                                          background: session.backgroundWatermark,
                                          unseen: session.unseenCount > 0 ? session.unseenCount : nil,
                                          fontSize: fontSize(session),
                                          splitFontSize: splitFontSize(session),
                                          scratchFontSize: scratchFontSize(session),
                                          surfaces: surfaces)
            }
            return ControlWorkspaceNode(id: workspace.id.uuidString, name: workspace.name,
                                        active: workspace.id == activeWorkspaceID,
                                        focused: focusedWorkspaceIDs.contains(workspace.id) ? true : nil,
                                        collapsed: workspace.isExpanded ? nil : true,
                                        sessions: sessions)
        }
        return ControlTree(workspaces: nodes, idleMs: idleMs(), autoFollowMs: autoFollowMs,
                           sidebarVisible: sidebarVisible, sidebarMode: sidebarMode.rawValue,
                           workspaceFilter: focusEnabled,
                           quickVisible: quickVisible(), zoomedSurface: zoomedSurface(),
                           dashboardMembers: dashboardMembers(),
                           dashboardHighlighted: dashboardHighlighted(),
                           dashboardFontSize: dashboardFontSize(),
                           dashboardFontMode: dashboardFontMode(),
                           pickPending: pickPending())
    }

    /// The tree's `paneOverlays`: the panes covered by their own overlay, omitted when neither is.
    private func paneOverlays(_ session: Session) -> [String]? {
        let panes = session.openPaneOverlays.map(\.rawValue)
        return panes.isEmpty ? nil : panes
    }

    /// Creates a workspace and appends it. With `revealNewWorkspace` (the default) and the filter ON, the new
    /// workspace JOINS the marked set so it is immediately visible — the auto-reveal contract, like
    /// `addSession`; widening rather than clearing keeps the rest filtered. `false` leaves the filter
    /// untouched: a background `session.new --no-select` create must not widen the view. `collapsed: true`
    /// (backing `workspace.new --collapsed`) starts it collapsed against the runtime default of expanded, so
    /// it can be filled with `addSession(select: false)` unopened. `revealNewWorkspace` also decides
    /// targeting: true makes this workspace `currentWorkspaceID` for as long as `freshWorkspaceID` holds it,
    /// false leaves the target where it is. `ensureWorkspace(named:revealNewWorkspace:)` forwards both.
    @discardableResult
    public func addWorkspace(name: String, collapsed: Bool = false, revealNewWorkspace: Bool = true) -> Workspace {
        let workspace = Workspace(name: name, isExpanded: !collapsed)
        workspaces.append(workspace)
        if revealNewWorkspace {
            revealNewFocusMember(workspace.id)
            freshWorkspaceID = workspace.id
        }
        scheduleTreeChanged()
        save()
        return workspace
    }

    /// The first workspace whose name exactly equals `name` (case-sensitive, trimmed); nil when none matches
    /// or `name` is blank. Backs `session.new --workspace-name` (addressing by sidebar label, not id).
    public func workspace(named name: String) -> Workspace? {
        guard let needle = name.trimmedOrNil else { return nil }
        return workspaces.first { $0.name == needle }
    }

    /// The workspace named `name`, created if none exists (idempotent); `revealNewWorkspace` (default true)
    /// is forwarded to `addWorkspace` on the create path. Nil only when blank. Backs `--workspace-name --create-workspace`.
    @discardableResult
    public func ensureWorkspace(named name: String, revealNewWorkspace: Bool = true) -> Workspace? {
        guard let needle = name.trimmedOrNil else { return nil }
        return workspace(named: needle) ?? addWorkspace(name: needle, revealNewWorkspace: revealNewWorkspace)
    }

    /// Creates a session in the given workspace and selects it when `select` (the default); `select: false`
    /// appends it in the background, leaving selection/focus/recency untouched (`session.new --no-select`).
    /// `name` seeds `customName` (trimmed; blank = the auto basename, matching `renameSession`). `at` nil
    /// appends, else inserts at the clamped index (`0...count`), backing `--after`/`--before`. Nil if no
    /// workspace matches.
    @discardableResult
    public func addSession(toWorkspace workspaceID: UUID, cwd: String, command: String? = nil,
                           name: String? = nil, wait: Bool = false, at index: Int? = nil, select: Bool = true) -> Session? {
        guard let wsIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let session = Session(initialCwd: cwd, customName: name?.trimmedOrNil)
        session.initialCommand = command
        session.commandWait = wait
        if let index {
            let destination = max(0, min(index, workspaces[wsIndex].sessions.count))
            workspaces[wsIndex].sessions.insert(session, at: destination)
        } else {
            workspaces[wsIndex].sessions.append(session)
        }
        if select {
            selectedSessionID = session.id
            disableFocusIfSelectionOutsideSet(session.id) // a control-driven add into another workspace must reveal it
            recordRecency()
        }
        emitSessionCreated(session, workspace: workspaceID)
        save()
        return session
    }

    /// Selects a session (nil clears) and persists. A non-nil id matching no session is ignored, leaving the
    /// current selection; nil always deselects. Backs the sidebar's `List(selection:)`, so a click persists
    /// (debounced) rather than waiting for the next structural mutation, and clears the visited session's
    /// unseen badge. An `autoReset` indicator (the one-time `completed` flash) must not persist once you leave
    /// it, so it resets to idle on BOTH the session moved to and the one moved from; a non-`autoReset` one
    /// (active/blocked) is untouched. Returns the destination's pre-reset indicator to reveal its tagged pane.
    @discardableResult
    public func selectSession(_ sessionID: UUID?, sidebarSelection selectionIDs: [UUID]? = nil) -> AgentIndicator? {
        if let sessionID, session(withID: sessionID) == nil { return nil }
        let destinationIndicator = sessionID.flatMap { session(withID: $0)?.agentIndicator }
        let previous = selectedSessionID
        selectedSessionID = sessionID
        if let selectionIDs {
            setSidebarSelection(selectionIDs)
        } else {
            replaceSidebarSelection(with: sessionID)
        }
        disableFocusIfSelectionOutsideSet(sessionID)
        if let sessionID { clearUnseen(sessionID) }
        clearAutoResetIndicator(sessionID)
        clearAutoResetIndicator(previous)
        recordRecency()
        scheduleSave()
        return destinationIndicator
    }

    /// Reset a session's indicator to idle when marked `autoReset`; no-op for nil, unknown, or non-autoReset.
    private func clearAutoResetIndicator(_ id: UUID?) {
        guard let id, let session = session(withID: id), session.agentIndicator.autoReset else { return }
        setAgentIndicator(AgentIndicator(), forSession: id)
    }

    /// Clears a session's unseen-notification badge; no-op for an unknown id, and never saves (ephemeral).
    public func clearUnseen(_ sessionID: UUID) {
        session(withID: sessionID)?.unseenCount = 0
    }

    /// Pushes the current selection to the front of the recency stack (the Ctrl-Tab order); no-op when none.
    func recordRecency() {
        if let selectedSessionID { sessionRecency.push(selectedSessionID) }
    }

    func removeFromRecency(_ id: UUID) {
        sessionRecency.remove(id)
    }

    /// Removes a session, tears down its surface, and — if it was active — reselects the most-recently-active
    /// surviving session in scope (`closeReselectionTarget(after:)`), falling back to the positional neighbor.
    public func closeSession(_ sessionID: UUID) {
        guard let location = location(ofSession: sessionID) else { return }
        let wasActive = selectedSessionID == sessionID
        let workspace = workspaces[location.workspaceIndex]
        let removed = workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex)
        emitSessionClosed(removed, workspace: workspace.id)
        recordRecentClosedSession(removed, workspaceID: workspace.id, workspaceName: workspace.name,
                                  workspaceIndex: location.workspaceIndex, sessionIndex: location.sessionIndex)
        removed.surface?.teardown()
        removed.splitSurface?.teardown()
        removed.overlaySurface?.teardown()
        removed.teardownPaneOverlays()
        removed.scratchSurface?.teardown()
        WatermarkStorage.removeRenderedText(sessionID: sessionID) // drop any rendered .text PNG; the session is gone
        sessionRecency.remove(sessionID)
        if wasActive {
            selectedSessionID = closeReselectionTarget(after: location)
            replaceSidebarSelection(with: selectedSessionID)
            disableFocusIfSelectionOutsideSet(selectedSessionID) // the reselected session may live outside the marked set
            recordRecency()
        } else {
            pruneSidebarSelection()
        }
        save()
    }

    /// Whether a workspace may be removed: one is always kept, so only when more than one exists.
    public var canRemoveWorkspace: Bool { workspaces.count > 1 }

    /// Removes a workspace and every session in it, tearing down their surfaces and pruning the recency
    /// stack. No-ops unless more than one workspace exists (the last is kept). If the active session lived
    /// there, `workspaceRemovalTarget(at:)` reselects the most recent still VISIBLE session, falling back to
    /// the positional walk only when nothing is visible, nil when none remain.
    public func removeWorkspace(_ workspaceID: UUID) {
        guard canRemoveWorkspace, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let workspace = workspaces[index]
        let removingActive = selectedSessionID.map { id in workspace.sessions.contains { $0.id == id } } ?? false
        // record the membership BEFORE `dropFocusMember` below prunes it, so Reopen Closed Item can re-mark it
        recordRecentClosedWorkspace(workspace, selectedSessionID: removingActive ? selectedSessionID : nil,
                                    focusMember: focusedWorkspaceIDs.contains(workspaceID))
        for session in workspace.sessions { emitSessionClosed(session, workspace: workspace.id) }
        if workspace.sessions.isEmpty { scheduleTreeChanged() }
        for session in workspace.sessions {
            session.surface?.teardown()
            session.splitSurface?.teardown()
            session.overlaySurface?.teardown()
            session.teardownPaneOverlays()
            session.scratchSurface?.teardown()
            WatermarkStorage.removeRenderedText(sessionID: session.id) // drop any rendered .text PNG; the session is gone
            sessionRecency.remove(session.id)
        }
        dropFocusMember(workspaceID) // a marked root is gone; the filter goes with the last member
        workspaces.remove(at: index)
        forgetFreshWorkspace(workspaceID)
        if removingActive {
            selectedSessionID = workspaceRemovalTarget(at: index)
            replaceSidebarSelection(with: selectedSessionID)
            disableFocusIfSelectionOutsideSet(selectedSessionID) // the reselected session may live outside the marked set
            recordRecency()
        } else {
            pruneSidebarSelection()
        }
        save()
    }

    /// Moves a session to another workspace (or reorders within one), keeping the **same** `Session` instance
    /// so its attached surface and live shell survive. `index` is the destination position **after** the
    /// move's removal (clamped); nil appends. `selectedSessionID` is unaffected — the id is stable. No-ops on
    /// an unknown session or target workspace, and a same-workspace move to the current slot leaves order
    /// unchanged. Moving the **active** session out of the marked set suspends the focus filter while KEEPING
    /// the set (the auto-reveal contract: the active session must stay inside the visible set); a non-active
    /// session leaves the filter intact.
    public func moveSession(_ sessionID: UUID, toWorkspace targetID: UUID, at index: Int? = nil) {
        guard let source = location(ofSession: sessionID) else { return }
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }) else { return }
        let before = workspaces.map { $0.sessions.map(\.id) }

        let session = workspaces[source.workspaceIndex].sessions.remove(at: source.sessionIndex)
        let destination = max(0, min(index ?? workspaces[targetIndex].sessions.count, workspaces[targetIndex].sessions.count))
        workspaces[targetIndex].sessions.insert(session, at: destination)
        if sessionID == selectedSessionID { disableFocusIfSelectionOutsideSet(sessionID) }
        pruneSidebarSelection()
        if before != workspaces.map({ $0.sessions.map(\.id) }) { scheduleTreeChanged() }
        save()
    }

    /// Moves selected sessions in their current tree order. With `index == nil`, a multi-session move appends
    /// cross-workspace sessions and leaves those already in the target in place; a one-session call matches
    /// `moveSession` and appends even within that workspace. With an explicit `index` (a drag drop), every
    /// dragged session is removed first, then the block inserted at that post-removal index. Returns the count.
    @discardableResult
    public func moveSessions(_ sessionIDs: [UUID], toWorkspace targetID: UUID, at index: Int? = nil) -> Int {
        guard workspaces.contains(where: { $0.id == targetID }) else { return 0 }
        let before = workspaces.map { $0.sessions.map(\.id) }
        var movingIDs = orderedSessionIDs(matching: Set(sessionIDs))
        // a one-element batch stays wire-equivalent to `moveSession`, so only multi-selection filters
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
        if let selectedSessionID, movingIDs.contains(selectedSessionID) { disableFocusIfSelectionOutsideSet(selectedSessionID) }
        pruneSidebarSelection()
        if before != workspaces.map({ $0.sessions.map(\.id) }) { scheduleTreeChanged() }
        save()
        return moving.count
    }

    /// Reorders a session one step within its own workspace (`up`/`down`/`top`/`bottom`) via `moveSession`.
    /// No-op (no write) on an unknown id or when the move would leave order unchanged (already at that end).
    public func reorderSession(_ id: UUID, _ direction: ReorderDirection) {
        guard let loc = location(ofSession: id) else { return }
        let count = workspaces[loc.workspaceIndex].sessions.count
        guard let dest = direction.destinationIndex(from: loc.sessionIndex, count: count) else { return }
        moveSession(id, toWorkspace: workspaces[loc.workspaceIndex].id, at: dest)
    }

    /// Moves a workspace to `index` among its siblings, mirroring `moveSession`'s remove/clamp/insert/save
    /// shape; `index` is the destination position **after** the move's removal (clamped). No-op on unknown.
    public func moveWorkspace(_ id: UUID, at index: Int) {
        guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let before = workspaces.map(\.id)
        let workspace = workspaces.remove(at: current)
        let dest = max(0, min(index, workspaces.count))
        workspaces.insert(workspace, at: dest)
        if before != workspaces.map(\.id) { scheduleTreeChanged() }
        save()
    }

    /// Reorders a workspace one step among its siblings (`up`/`down`/`top`/`bottom`) via `moveWorkspace`.
    /// No-op (no write) on an unknown id or when the move would leave order unchanged (already at that end).
    public func reorderWorkspace(_ id: UUID, _ direction: ReorderDirection) {
        guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard let dest = direction.destinationIndex(from: current, count: workspaces.count) else { return }
        moveWorkspace(id, at: dest)
    }

    /// The owning workspace id, the session's index in it, and that workspace's session count; nil for an
    /// unknown id. One tree walk for the sidebar drag handler, feeding the host-free `SidebarDrop` resolver.
    public func sessionLocation(ofSession id: UUID) -> (workspace: UUID, index: Int, count: Int)? {
        guard let loc = location(ofSession: id) else { return nil }
        let workspace = workspaces[loc.workspaceIndex]
        return (workspace.id, loc.sessionIndex, workspace.sessions.count)
    }

    /// Steps the selection through the flattened VISIBLE/FILTERED session list in the sidebar's visual order
    /// (`navigableSessions`: the flagged set in `.flagged` mode, the MARKED workspaces' sessions while the
    /// focus filter is applied, else all). `next`/`previous` move one and WRAP WITHIN that set, never leaking
    /// across the filter; `first`/`last` jump to its ends; with no/invalid selection `next`/`previous` land
    /// on the first session. No-op on an empty list. Routes through `selectSession`, inheriting recency,
    /// badge clearing, persistence and workspace derivation. Targets are always in-set, so nav never triggers
    /// `disableFocusIfSelectionOutsideSet` — that stays the safety net for an explicit cross-set select.
    @discardableResult
    public func navigateSession(_ direction: SessionNavigation) -> AgentIndicator? {
        let sessions = navigableSessions
        let ids = sessions.map(\.id)
        guard let first = ids.first, let last = ids.last else { return nil }
        let target: UUID
        switch direction {
        case .first: target = first
        case .last: target = last
        case .next, .previous:
            if let current = selectedSessionID, let i = ids.firstIndex(of: current) {
                let step = direction == .next ? 1 : -1
                target = ids[((i + step) % ids.count + ids.count) % ids.count] // cycle within the filtered set
            } else {
                target = first
            }
        case .nextAttention, .previousAttention:
            guard let found = attentionTarget(in: sessions, forward: direction == .nextAttention) else { return nil }
            target = found
        }
        return selectSession(target)
    }

    /// The next/previous session needing attention (`blocked`/`completed`) in the flattened order, scanning
    /// from the current selection and WRAPPING; the current session is excluded, so repeated steps cycle
    /// through the others. With no/invalid selection the scan starts from the tree end opposite the
    /// direction. Nil (a no-op) when no other attention session exists.
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

    /// Records a session's terminal font size (points) and persists it, debounced so a held ⌘+/⌘− ramp
    /// coalesces into one write. No-ops when unchanged, so a DPI-change cell-size event doesn't write.
    public func setFontSize(_ sessionID: UUID, _ size: Double) {
        guard let session = session(withID: sessionID), session.fontSize != size else { return }
        session.fontSize = size
        scheduleSave()
    }

    /// Clears every per-session font-size override (no write when none was set). Called on an appearance
    /// change: the shared ghostty `update_config` resets live surfaces to the default, so the pins must match.
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

    /// Sets this window's sidebar visibility and persists it. Clean no-op (no write) when unchanged, so menu,
    /// toolbar, palette and control callers need not duplicate the persistence gate.
    public func setSidebarVisible(_ visible: Bool) {
        guard sidebarVisible != visible else { return }
        sidebarVisible = visible
        save()
        // refresh ControlServer's window.list cache: a GUI-only toggle is no control command, so the cached
        // sidebarVisible would lag until the next one.
        NotificationCenter.default.post(name: .agtermSidebarVisibilityChanged, object: nil)
    }

    /// Flips this window's sidebar visibility and persists the new state.
    public func toggleSidebarVisible() {
        setSidebarVisible(!sidebarVisible)
    }

    /// Sets the sidebar mode and persists it; clean no-op when unchanged, so delta-computed control/menu
    /// callers stay idempotent. BOTH flips reselect when they would hide the active session.
    public func setSidebarMode(_ mode: SidebarMode) {
        guard sidebarMode != mode else { return }
        sidebarMode = mode
        pruneSidebarSelection()
        reselectIfSelectionHidden()
        save()
    }

    /// Sets one workspace's expand/collapse state and persists it; clean no-op for an unknown id or when
    /// unchanged. The sidebar calls this for a GENUINE per-row user toggle only (a row click or the
    /// disclosure triangle), never a programmatic reveal, so a deliberate collapse survives a later reveal of
    /// a session inside it and never touches another workspace's state (unlike `setWorkspacesExpanded`).
    public func setWorkspaceExpanded(_ id: UUID, expanded: Bool) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces[index].isExpanded != expanded else { return }
        workspaces[index].isExpanded = expanded
        save()
    }

    /// Marks each workspace expanded iff its id is in `expandedIDs`, one `save()` for the whole diff and no
    /// write when nothing changed. Backs Expand / Collapse Workspaces, which set every workspace at once;
    /// per-row toggles use `setWorkspaceExpanded` instead.
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

    /// The flagged sessions across all workspaces in tree order — the projection the flat sidebar renders.
    public var flaggedSessions: [Session] {
        workspaces.flatMap(\.sessions).filter(\.flagged)
    }

    // MARK: - Persistence

    /// Builds a `Snapshot` of the current tree; each session captures its live `currentCwd` (or `initialCwd`
    /// if no PWD report arrived). Runs on `@MainActor`; the result is `Sendable`, safe to hand to a writer.
    public func snapshot() -> Snapshot {
        let workspaceSnapshots = workspaces.map { workspace in
            let sessions = workspace.sessions.map(sessionSnapshot)
            // only a collapsed workspace writes the flag, so an all-expanded tree matches a legacy snapshot.
            return WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: sessions,
                                     collapsed: workspace.isExpanded ? nil : true)
        }
        // TREE order keeps the on-disk list deterministic (not the Set's hash order); an unmarked store omits
        // both focus keys, matching a file written before the set existed. `focusedWorkspaceID` stays unused.
        let focusIDs = workspaces.map(\.id).filter(focusedWorkspaceIDs.contains)
        return Snapshot(selectedSessionID: selectedSessionID, workspaces: workspaceSnapshots,
                        sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible, sidebarMode: sidebarMode,
                        focusedWorkspaceIDs: focusIDs.isEmpty ? nil : focusIDs,
                        focusEnabled: focusEnabled ? true : nil,
                        sessionRecency: sessionRecency.items)
    }

    /// Rebuilds the tree from a snapshot: fresh `Session`s (surfaces and shells spawn lazily on first
    /// display) keyed by the persisted ids so the restored `selectedSessionID` still resolves, replacing the
    /// current state wholesale. A persisted selection pointing at a session that no longer exists is cleared.
    /// Deliberately does NOT call `save()` — it loads what was just read from disk; the closing
    /// `reselectIfSelectionHidden` is the exception, since repairing a stranded selection is worth writing.
    /// `launchRestore` marks an APP-BOOTSTRAP restore, the only thing that arms a persisted `session.restore`
    /// override for this launch. It defaults to false because reopening a closed window mid-process reloads
    /// its store through here, and that RUNTIME caller must not execute anything.
    public func restore(from snapshot: Snapshot, launchRestore: Bool = false) {
        freshWorkspaceID = nil // live create-time state, never restored from disk
        // fold duplicate workspace ids into the first occurrence and keep only the first snapshot of a
        // repeated session id, else the rest stay unreachable past the first match and get re-saved.
        var seenSessionIDs: Set<UUID> = []
        workspaces = snapshot.workspaces.reduce(into: [Workspace]()) { restored, workspaceSnapshot in
            let sessions = workspaceSnapshot.sessions
                .filter { seenSessionIDs.insert($0.id).inserted }
                .map { session(from: $0, launchRestore: launchRestore) }
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
        restoreFocus(from: snapshot)
        if let id = snapshot.selectedSessionID, session(withID: id) == nil {
            selectedSessionID = nil
        } else {
            selectedSessionID = snapshot.selectedSessionID
        }
        replaceSidebarSelection(with: selectedSessionID)
        // re-seed the Ctrl-Tab order from the persisted list (dropping ids not in the restored tree); the
        // restored selection floats to the front, keeping the "previous session" slot truthful.
        let restoredIDs = Set(workspaces.flatMap(\.sessions).map(\.id))
        sessionRecency = RecencyStack(items: (snapshot.sessionRecency ?? []).filter { restoredIDs.contains($0) })
        recordRecency()
        // LAST, after the recency stack is re-seeded: the pick is MRU, so earlier finds an empty stack.
        reselectIfSelectionHidden()
    }

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
            return true
        } catch {
            log("save failed: \(error)")
            return false
        }
    }

    /// Debounces a `save()`, coalescing the rapid selection/font writes; used only by
    /// `selectSession`/`setFontSize`, while structural mutations call `save()` immediately.
    private func scheduleSave() {
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

    /// Picks the next selection after removing the session at `location`: the session that shifted into the
    /// removed slot, else the previous one in that workspace, else the first session of any remaining one.
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
                        initialCommand: session.initialCommand, commandWait: session.commandWait ? true : nil,
                        backgroundWatermark: session.backgroundWatermark,
                        restoreCommand: session.restoreCommand,
                        splitRestoreCommand: session.splitRestoreCommand)
    }

    func workspaceSnapshot(_ workspace: Workspace) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: workspace.sessions.map(sessionSnapshot),
                          collapsed: workspace.isExpanded ? nil : true)
    }

    /// Rebuilds one session from its snapshot. `launchRestore` marks an APP-BOOTSTRAP restore, the only path
    /// allowed to arm a persisted `restoreCommand` by copying it into the transient `pendingRestoreCommand`
    /// the surface factory consumes; it defaults to false so any other rebuild (a mid-process window reload,
    /// Reopen Closed Item) comes back with nothing armed.
    ///
    /// A split hidden at the last quit is NOT rebuilt (`hasSplit` follows `isSplit`), so its pinned override
    /// describes a pane that no longer exists and is DROPPED here, the rule `closeSplit` applies when a pane
    /// goes away. Keeping it would leave a value `tree` reports but no write can clear (`session.restore
    /// --pane right` is rejected without a split), and a fresh ⌘D split at the next quit would inherit it.
    func session(from snapshot: SessionSnapshot, launchRestore: Bool = false) -> Session {
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
        session.commandWait = snapshot.commandWait ?? false
        session.wasRestored = true
        session.backgroundWatermark = snapshot.backgroundWatermark
        session.restoreCommand = snapshot.restoreCommand
        session.splitRestoreCommand = session.isSplit ? snapshot.splitRestoreCommand : nil
        if launchRestore {
            session.pendingRestoreCommand = snapshot.restoreCommand
            if session.isSplit { session.pendingSplitRestoreCommand = session.splitRestoreCommand }
        }
        return session
    }

    func workspace(from snapshot: WorkspaceSnapshot) -> Workspace {
        Workspace(id: snapshot.id, name: snapshot.name, sessions: snapshot.sessions.map { session(from: $0) },
                  isExpanded: !(snapshot.collapsed ?? false))
    }

}
