import Foundation

/// App-facing operations a host must provide for commands routed through `ControlDispatcher`.
/// The dispatcher owns command parsing and response shape; the host keeps target resolution and
/// platform-specific side effects.
@MainActor
public protocol ControlActions {
    func controlTree(window: String?) -> ControlResponse
    func readEvents(_ options: ControlEventReadOptions) -> ControlResponse
    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse
    /// createSession with a creation tint; the default keeps tintless hosts working and refuses a tint.
    func createSession(_ options: ControlSessionCreateOptions, tint: SidebarTint?) -> ControlResponse
    func duplicateSession(_ target: String?, window: String?) -> ControlResponse
    /// Creates a companion of the target session, or a sibling when the target is itself a companion.
    func createCompanion(_ target: String?, options: CompanionOptions, window: String?) async -> ControlResponse
    /// Creates a page companion of the target session showing `options.page` full size.
    func createPageCompanion(_ target: String?, window: String?, options: ControlSessionOverlayOpenOptions) async -> ControlResponse
    /// Creates a companion copying the target's layout and running another copy of each pane's program.
    func duplicateAsCompanion(_ target: String?, window: String?, select: Bool) async -> ControlResponse
    /// Hands out one attachment of the target page companion to another Mac.
    func attachCompanionPage(_ target: String?, window: String?) -> ControlResponse
    /// Folds or unfolds a parent's companions in the sidebar tree.
    func setSessionExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse
    func selectSession(_ target: String?, window: String?) -> ControlResponse
    func goSession(window: String?, direction: SessionNavigation) -> ControlResponse
    func closeSession(_ target: String?, window: String?) -> ControlResponse
    func closeSessions(_ targets: [String], window: String?) -> ControlResponse
    /// The `session.close --undoable` forms; their defaults refuse an undoable request.
    func closeSession(_ target: String?, window: String?, undoable: Bool) -> ControlResponse
    func closeSessions(_ targets: [String], window: String?, undoable: Bool) -> ControlResponse
    func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse
    func revealSession(_ target: String?, window: String?) -> ControlResponse
    func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse
    /// createWorkspace with a creation tint; the default keeps tintless hosts working and refuses a tint.
    func createWorkspace(window: String?, name: String?, collapsed: Bool, tint: SidebarTint?) -> ControlResponse
    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse
    /// Step the placement store's CURRENT workspace one place through the sidebar's visible order, selecting
    /// the destination's first session when it has one — an EMPTY destination becomes current with the
    /// selection left where it was. Relative, so no target: the counterpart of `session.go` one level up.
    func goWorkspace(window: String?, direction: WorkspaceNavigation) -> ControlResponse
    func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse
    func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse
    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse
    func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse
    func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse
    func focusWorkspace(_ target: String?, window: String?, mode: ControlWorkspaceFocusMode) -> ControlResponse
    /// Turn a window's workspace focus filter on/off WITHOUT touching the marked set. Window-scoped, so
    /// it takes no workspace target — the host resolves the store from `window` (frontmost when nil).
    func setWorkspaceFilter(window: String?, mode: ControlToggleMode) -> ControlResponse
    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse
    /// Flags or unflags every session of the target workspace as one value; `toggle` unflags only when all are.
    func setWorkspaceFlag(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse
    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse
    /// moveFlaggedSession moves the flagged target just before or after the flagged `anchor` in its window's
    /// saved flagged order.
    func moveFlaggedSession(_ target: String?, window: String?, anchor: String,
                            placement: FlaggedOrderPlacement) -> ControlResponse
    /// Sets or clears the session's title-bar context; `context` is already trimmed and validated, and nil
    /// means clear.
    func setSessionContext(_ target: String?, window: String?, context: String?) -> ControlResponse
    /// Sets or clears a session's sidebar tint; the dispatcher has parsed the color and parts.
    func setSessionTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse
    /// Sets or clears a workspace row's own tint.
    func setWorkspaceTint(_ target: String?, window: String?, update: ControlTintUpdate) -> ControlResponse
    func markSessionSeen(_ target: String?, window: String?) -> ControlResponse
    func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) async -> ControlResponse
    /// Write a pane's PERSISTED restore-command override (consumed on the NEXT launch, never this run).
    /// The host resolves the target session and the live pane slot, then stores the tri-state value; it
    /// also owns the pane rejections that need a session (`scratch`, `right` without a split, an
    /// unresolvable `paneID` given without an explicit `pane`).
    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse
    /// restartSessionPane replaces one live pane's shell with a new one running `options.command`, keeping
    /// the pane and its stable id. The default below keeps existing hosts source-compatible.
    func restartSessionPane(_ target: String?, window: String?,
                            options: ControlSessionRestartOptions) async -> ControlResponse
    /// Source-compatible axis-agnostic entry point retained for existing conformers and callers.
    func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse
    /// Axis-aware entry point. Its default delegates to the original method so an existing conformer does
    /// not have to implement the new requirement until it needs axis support.
    func splitSession(_ target: String?, window: String?, mode: String?, axis: SplitAxis?) -> ControlResponse
    /// Tear the split pane down rather than hide it, the write side `splitSession`'s `on|off|toggle` cannot
    /// express: the surface dies and `hasSplit`/`splitRatio`/`splitFocused` go nil in `tree`.
    func closeSessionSplit(_ target: String?, window: String?) -> ControlResponse
    /// Exchange the two live pane roles. The default below keeps existing hosts source-compatible and
    /// reports that the optional operation is unsupported.
    func swapSessionPanes(_ target: String?, window: String?) async -> ControlResponse
    /// Take the lead of a pane's zmx daemon for this Mac, as a key press on the pane's cover does. The
    /// default below keeps existing hosts source-compatible.
    func takeSessionLead(_ target: String?, window: String?, pane: StatusPane?) -> ControlResponse
    func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse
    /// Selection-aware entry point: `follow` selects the target when showing its scratch. Its default
    /// delegates to the original method so an existing conformer keeps its own selection behavior.
    func scratchSession(_ target: String?, window: String?, mode: String?, command: String?,
                        follow: Bool) -> ControlResponse
    func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse
    func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse
    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse
    /// The addressed surface's cursor column. Takes `surface.zoom`'s target vocabulary, `quick` included,
    /// because it addresses the same set of surfaces; unlike zoom it is a pure read and changes nothing.
    func readSurfaceCursor(_ target: String?, window: String?) -> ControlResponse
    /// readSurfaceCursor with a non-empty `paneID` takes a session target; the token picks the pane.
    func readSurfaceCursor(_ target: String?, window: String?, paneID: String?) -> ControlResponse
    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse
    func font(_ target: String?, window: String?, pane: StatusPane?, action: String) -> ControlResponse
    func reloadKeymap() -> ControlResponse
    func listKeymap() -> ControlResponse
    /// runCustomCommand starts the one custom command named `name` against the addressed session. Ok
    /// means the process started, not that it finished or succeeded.
    func runCustomCommand(name: String, target: String?, window: String?) -> ControlResponse
    /// `hooks.reload` / `hooks.list`, app-global like the keymap pair.
    func reloadHooks() -> ControlResponse
    func listHooks() -> ControlResponse
    /// `recent.list` / `recent.clear`, app-global over the one Recent Closed list.
    func listRecentClosed() -> ControlResponse
    func clearRecentClosed() -> ControlResponse
    /// `recent.open` restores the entry `target` names, the newest when nil, into `window`'s store or the
    /// frontmost one. The host owns resolution and reports the window the entry actually went to.
    func openRecentClosed(_ target: String?, window: String?) -> ControlResponse
    /// `browser.clear` empties the saved browser store; the reply waits for the removal to finish.
    func clearBrowser() async -> ControlResponse
    /// `browser.links` sets where a clicked web link opens, or with nil only reads it; the reply's text is
    /// the effective mode either way.
    func linkOpenMode(_ mode: LinkOpenMode?) -> ControlResponse
    func appIdentity() -> ControlResponse
    func reloadGhosttyConfig() -> ControlResponse
    func sendNotification(_ target: String?, window: String?, title: String?, body: String) -> ControlResponse
    func setTheme(args: ControlArgs?) -> ControlResponse
    func listThemes() -> ControlResponse
    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse
    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse
    func setFlaggedViewLayout(_ mode: ControlFlaggedLayoutMode) -> ControlResponse
    func expandSidebar(window: String?) -> ControlResponse
    func collapseSidebar(window: String?) -> ControlResponse
    func setSidebarWidth(_ points: Double, window: String?) -> ControlResponse
    func setQuickTerminal(mode: String?) -> ControlResponse
    func typeQuick(text: String) async -> ControlResponse
    func readQuickText(all: Bool, lines: Int?) async -> ControlResponse
    func typeSession(_ target: String?, window: String?, options: ControlSessionTypeOptions) async -> ControlResponse
    func copySessionSelection(_ target: String?, window: String?) -> ControlResponse
    func pasteSession(_ target: String?, window: String?, pane: StatusPane?) -> ControlResponse
    func selectAllSession(_ target: String?, window: String?) -> ControlResponse
    func searchSession(_ target: String?, window: String?,
                       text: String?, to: String?) async -> ControlResponse
    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse
    func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse
    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse
    /// resizeSessionOverlay with `points` re-sizes from `sizePercent` with exactly those axes, or alone changes only them.
    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?,
                              points: OverlayPointSize) -> ControlResponse
    func reloadSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, current: Bool) -> ControlResponse
    func navigateSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?,
                                navigation: HtmlNavigation) -> ControlResponse
    func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse
    /// Hides, shows or toggles the session's overlays, or one pane's; a hidden overlay keeps running.
    func setSessionOverlayVisibility(_ target: String?, window: String?, pane: OverlayPane?,
                                     mode: OverlayVisibilityMode) -> ControlResponse
    /// Answers the page in the addressed slot with `value` and closes it; `session.overlay.result --page` reads it.
    func submitSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, value: String) -> ControlResponse
    /// The selector outcome of page `pageID`, readable after the page and its session are gone.
    func htmlPageResult(_ pageID: UUID) -> ControlResponse
    /// The overlay's own current selection, the arm `session.copy` cannot reach: that one addresses the pane
    /// UNDER the overlay, and the selection the user made is on the surface covering it. `pane` nil reads
    /// the session-wide overlay.
    func copySessionOverlaySelection(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse
    /// The overlay's own terminal buffer, `session.text`'s counterpart for the covering surface. A TUI's
    /// buffer is its drawn screen, so this reads what is rendered, not what the program would print.
    func readSessionOverlayText(_ target: String?, window: String?,
                                options: ControlSessionOverlayTextOptions) -> ControlResponse
    /// Post a message panel over the session, occupying the same overlay slot a program overlay uses. The
    /// dispatcher validated the text, color, percent, and position; the host measures the terminal font,
    /// renders the message to a file, and drives the store.
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse
    func openHud(_ target: String?, window: String?, spec: HudSpec,
                 placement: ControlHudPlacement) -> ControlResponse
    /// Replace a live panel's text in place — same surface, no respawn. `spec.backgroundColor` cannot change
    /// here, the surface having read it once at creation.
    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse
    func updateHud(_ target: String?, window: String?, spec: HudSpec,
                   placement: ControlHudPlacement) -> ControlResponse
    func closeHud(_ target: String?, window: String?) -> ControlResponse
    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse
    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse
    func windowNew(name: String?, minimized: Bool) async -> ControlResponse
    func windowList() -> ControlResponse
    func windowSelect(_ target: String?) async -> ControlResponse
    func windowGo(direction: WorkspaceNavigation) -> ControlResponse
    func windowClose(_ target: String?) async -> ControlResponse
    func windowRename(_ target: String?, name: String) -> ControlResponse
    func windowDelete(_ target: String?) -> ControlResponse
    func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse
    func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse
    func windowZoom(_ target: String?) -> ControlResponse
    func windowFullscreen(_ target: String?) -> ControlResponse
    func windowMinimize(_ target: String?, mode: ControlToggleMode) async -> ControlResponse
    /// Open a native picker. The host owns window resolution, registry lookup, and presentation.
    func openPick(_ pick: PendingPick, window: String?, follow: Bool) -> ControlResponse
    /// Read a native picker's current result. The host owns window resolution and registry lookup.
    func pickResult(_ target: String, window: String?) -> ControlResponse
    /// Cancel a native picker. The host owns window resolution, registry lookup, and dismissal.
    func cancelPick(_ target: String, window: String?) -> ControlResponse
    /// openAsk lets the host resolve a validated dialog's window and session or pane anchor.
    func openAsk(_ ask: PendingAsk, target: String?, window: String?,
                 placement: ControlAskPlacement, follow: Bool) -> ControlResponse
    /// askResult reads the current or retained outcome by globally unique dialog id.
    func askResult(_ target: String, window: String?) -> ControlResponse
    /// cancelAsk administratively cancels a dialog without answering a named button.
    func cancelAsk(_ target: String, window: String?) -> ControlResponse
    func clearRestoreCommands() -> ControlResponse
    /// Capture every open pane's foreground command now, the same read `applicationWillTerminate` does. The
    /// host owns the `sysctl` read, the save, and the count it reports back.
    func captureRestoreCommands() -> ControlResponse
    /// The restore-mode policy: what settings hold, what this launch requested, and what it got.
    func readRestoreMode() -> ControlResponse
    /// Persist the mode for the NEXT launch. The host owns the save and must report a failed write rather
    /// than leaving memory claiming a value the disk rejected.
    func setRestoreMode(_ mode: RestoreMode) -> ControlResponse
    /// The daemon inventory: observed daemons joined against the panes that claim them.
    func listZmxDaemons() -> ControlResponse
    /// Kill the daemons no pane claims and nothing is attached to.
    func pruneZmxDaemons() -> ControlResponse
    /// readZmxScreen returns a daemon's own screen by daemon name, which reaches a pane no open window
    /// shows. `fullBuffer` adds the retained scrollback; `lines` keeps the last N of it.
    func readZmxScreen(name: String, fullBuffer: Bool, lines: Int?) -> ControlResponse
    /// Destroy ONE pane's daemon. The host resolves the owner against the inventory rather than the open
    /// stores, since this reaches closed and unindexed claims the target resolver cannot see.
    func killZmxDaemon(target: String, window: String?, pane: ZmxPaneRole) -> ControlResponse
    /// Confirm the Live sessions reset without the dialog: the host selects the panes, refuses outside Live
    /// or on an incomplete inventory, answers, and quits only after this reply is written.
    func resetLiveSessions() -> ControlResponse
    /// Another machine's attachable sessions. Async because it runs ssh: a blocking wait here would hold
    /// the main actor for the whole network deadline.
    func remoteTree(host: String?) async -> ControlResponse
    /// Create a local session attached to `session` on `host`. Resolves the remote itself before inserting
    /// anything, so a session that has gone since the tree was read creates nothing.
    func attachRemoteSession(host: String, session: String) async -> ControlResponse
    /// Accept a viewer's presentation stream. After an ok answer the host speaks frames on that connection.
    func openPresentation(session: String) -> ControlResponse
    /// Claim a remote overlay job for the helper asking. After an ok answer the connection carries job frames.
    func claimOverlayJob(_ job: String) -> ControlResponse
    /// claimPageServe claims a handed-over page's channel with its single-use token. After an ok answer the
    /// connection carries page channel frames.
    func claimPageServe(_ token: String) -> ControlResponse
    /// Attach into an open local window, defaulting to the frontmost window after discovery.
    func attachRemoteSession(host: String, session: String, window: String?) async -> ControlResponse
    /// attachRemoteGroup attaches a remote top-level session, then each companion its origin lists, from one
    /// discovery read. A partial attach answers not ok with `result.id` and `result.remoteGroup` still set.
    func attachRemoteGroup(host: String, session: String, window: String?) async -> ControlResponse
}
