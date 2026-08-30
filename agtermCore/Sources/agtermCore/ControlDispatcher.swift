import Foundation

/// App-facing operations a host must provide for commands routed through `ControlDispatcher`.
/// The dispatcher owns command parsing and response shape; the host keeps target resolution and
/// platform-specific side effects.
@MainActor
public protocol ControlActions {
    func controlTree(window: String?) -> ControlResponse
    func readEvents(_ options: ControlEventReadOptions) -> ControlResponse
    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse
    func duplicateSession(_ target: String?, window: String?) -> ControlResponse
    func selectSession(_ target: String?, window: String?) -> ControlResponse
    func goSession(window: String?, direction: SessionNavigation) -> ControlResponse
    func closeSession(_ target: String?, window: String?) -> ControlResponse
    func closeSessions(_ targets: [String], window: String?) -> ControlResponse
    func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse
    func revealSession(_ target: String?, window: String?) -> ControlResponse
    func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse
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
    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse
    func markSessionSeen(_ target: String?, window: String?) -> ControlResponse
    func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) -> ControlResponse
    /// Write a pane's PERSISTED restore-command override (consumed on the NEXT launch, never this run).
    /// The host resolves the target session and the live pane slot, then stores the tri-state value; it
    /// also owns the pane rejections that need a session (`scratch`, `right` without a split, an
    /// unresolvable `paneID` given without an explicit `pane`).
    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse
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
    func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse
    func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse
    func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse
    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse
    /// The addressed surface's cursor column. Takes `surface.zoom`'s target vocabulary, `quick` included,
    /// because it addresses the same set of surfaces; unlike zoom it is a pure read and changes nothing.
    func readSurfaceCursor(_ target: String?, window: String?) -> ControlResponse
    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse
    func font(_ target: String?, window: String?, pane: String?, action: String) -> ControlResponse
    func reloadKeymap() -> ControlResponse
    func listKeymap() -> ControlResponse
    func appIdentity() -> ControlResponse
    func reloadGhosttyConfig() -> ControlResponse
    func sendNotification(_ target: String?, window: String?, title: String?, body: String) -> ControlResponse
    func setTheme(args: ControlArgs?) -> ControlResponse
    func listThemes() -> ControlResponse
    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse
    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse
    func expandSidebar(window: String?) -> ControlResponse
    func collapseSidebar(window: String?) -> ControlResponse
    func setQuickTerminal(mode: String?) -> ControlResponse
    func typeQuick(text: String) async -> ControlResponse
    func readQuickText(all: Bool, lines: Int?) async -> ControlResponse
    func typeSession(_ target: String?, window: String?, options: ControlSessionTypeOptions) async -> ControlResponse
    func copySessionSelection(_ target: String?, window: String?) -> ControlResponse
    func pasteSession(_ target: String?, window: String?) -> ControlResponse
    func selectAllSession(_ target: String?, window: String?) -> ControlResponse
    func searchSession(_ target: String?, window: String?,
                       text: String?, to: String?) async -> ControlResponse
    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse
    func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse
    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse
    func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse
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
    /// Replace a live panel's text in place — same surface, no respawn. `spec.backgroundColor` cannot change
    /// here, the surface having read it once at creation.
    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse
    func closeHud(_ target: String?, window: String?) -> ControlResponse
    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse
    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse
    func windowNew(name: String?, minimized: Bool) async -> ControlResponse
    func windowList() -> ControlResponse
    func windowSelect(_ target: String?) async -> ControlResponse
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
    func clearRestoreCommands() -> ControlResponse
    /// Capture every open pane's foreground command now, the same read `applicationWillTerminate` does. The
    /// host owns the `sysctl` read, the save, and the count it reports back.
    func captureRestoreCommands() -> ControlResponse
}

public extension ControlActions {
    func splitSession(_ target: String?, window: String?, mode: String?, axis _: SplitAxis?) -> ControlResponse {
        splitSession(target, window: window, mode: mode)
    }

    func swapSessionPanes(_: String?, window _: String?) async -> ControlResponse {
        ControlResponse(ok: false, error: "session.swap is not supported by this host")
    }
}

public struct ControlSessionTypeOptions: Equatable, Sendable {
    public let text: String
    public let select: Bool
    public let pane: String?

    public init(text: String, select: Bool, pane: String?) {
        self.text = text
        self.select = select
        self.pane = pane
    }
}

public struct ControlSessionOverlayOpenOptions: Equatable, Sendable {
    public let command: String
    public let cwd: String?
    public let wait: Bool
    public let sizePercent: Int?
    public let backgroundColor: String?
    public let follow: Bool
    /// The pane to cover, nil for the session-wide overlay. A pane overlay is always full, so this and
    /// `sizePercent` are mutually exclusive (rejected in the dispatcher).
    public let pane: OverlayPane?

    public init(command: String, cwd: String?, wait: Bool, sizePercent: Int?, backgroundColor: String?,
                follow: Bool = false, pane: OverlayPane? = nil) {
        self.command = command
        self.cwd = cwd
        self.wait = wait
        self.sizePercent = sizePercent
        self.backgroundColor = backgroundColor
        self.follow = follow
        self.pane = pane
    }
}

public struct ControlSessionBackgroundOptions: Equatable, Sendable {
    public let watermark: BackgroundWatermark?

    public init(watermark: BackgroundWatermark?) {
        self.watermark = watermark
    }
}

public struct ControlSessionTextOptions: Equatable, Sendable {
    public let pane: String?
    public let paneID: String?
    public let all: Bool
    public let lines: Int?

    public init(pane: String?, paneID: String? = nil, all: Bool, lines: Int?) {
        self.pane = pane
        self.paneID = paneID
        self.all = all
        self.lines = lines
    }
}

/// `session.overlay.text`'s inputs. `pane` is the parsed `OverlayPane` rather than
/// `ControlSessionTextOptions`' raw string: the overlay family takes only `left`/`right`, so the dispatcher
/// resolves it and the host never re-parses a vocabulary it could widen by accident.
public struct ControlSessionOverlayTextOptions: Equatable, Sendable {
    public let pane: OverlayPane?
    public let all: Bool
    public let lines: Int?

    public init(pane: OverlayPane?, all: Bool, lines: Int?) {
        self.pane = pane
        self.all = all
        self.lines = lines
    }
}

/// Routes control commands through a host-provided action seam. The dispatcher owns command parsing and
/// response shape; host actions keep target resolution, AppKit state, and terminal-surface side effects.
@MainActor
public struct ControlDispatcher {
    let actions: any ControlActions

    public init(actions: any ControlActions) {
        self.actions = actions
    }

    public func dispatch(_ request: ControlRequest) async -> ControlResponse? {
        switch request.cmd {
        case .tree:
            return actions.controlTree(window: request.args?.window)
        case .eventsRead:
            return dispatchEventsRead(request)
        case .sessionNew, .sessionDuplicate, .sessionSelect, .sessionGo, .sessionClose, .sessionRename,
                .sessionReveal, .sessionMove, .sessionFlag, .sessionSeen, .sessionStatus, .sessionRestore:
            return dispatchSessionCommand(request)
        case .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionScratch, .sessionFocus, .sessionResize,
                .surfaceZoom, .surfaceCursor, .sessionType,
                .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch, .sessionOverlayOpen,
                .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult, .sessionOverlayCopy,
                .sessionOverlayText, .sessionBackground,
                .sessionText:
            return await dispatchSessionSurfaceCommand(request)
        case .workspaceNew, .workspaceSelect, .workspaceGo, .workspaceRename, .workspaceDelete,
                .workspaceMove, .workspaceFocus, .workspaceFilter, .workspaceCollapse, .workspaceExpand:
            return dispatchWorkspaceCommand(request)
        case .quick, .fontInc, .fontDec, .fontReset, .keymapReload, .keymapList,
                .configReload, .notify, .themeSet, .themeList, .sidebar, .sidebarMode, .sidebarExpand,
                .sidebarCollapse, .restoreClear, .restoreCapture, .version:
            return dispatchAppCommand(request)
        case .quickType, .quickText:
            return await dispatchQuickCommand(request)
        case .windowNew, .windowList, .windowSelect, .windowClose, .windowRename,
                .windowDelete, .windowResize, .windowMove, .windowZoom, .windowFullscreen, .windowMinimize:
            return await dispatchWindowCommand(request)
        case .dashboard:
            return dispatchDashboard(request)
        case .debugAppearance:
            // UI-test-only seam handled app-side in `ControlServer` (needs AppKit + `ContentView.isUITestLaunch`).
            return nil
        case .pickOpen, .pickResult, .pickCancel:
            return dispatchPickCommand(request)
        case .sessionHudOpen, .sessionHudUpdate, .sessionHudClose:
            return dispatchHudCommand(request)
        }
    }

    private func dispatchEventsRead(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let cursor: ControlEventCursor?
        switch (args?.run, args?.after) {
        case (nil, nil):
            cursor = nil
        case (.some, nil), (nil, .some):
            return ControlResponse(ok: false, error: ControlEventRequestError.cursorPair)
        case let (.some(runText), .some(afterText)):
            guard let run = UUID(uuidString: runText) else {
                return ControlResponse(ok: false, error: ControlEventRequestError.invalidRun)
            }
            guard let after = UInt64(afterText) else {
                return ControlResponse(ok: false, error: ControlEventRequestError.invalidCursor)
            }
            cursor = ControlEventCursor(run: run, after: after)
        }

        let limit = args?.limit ?? 100
        guard (1...1_000).contains(limit) else {
            return ControlResponse(ok: false, error: ControlEventRequestError.invalidLimit)
        }

        var parsedKinds = Set<ControlEventKind>()
        for field in args?.kinds ?? [] {
            for component in field.split(separator: ",", omittingEmptySubsequences: false) {
                let rawKind = component.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let kind = ControlEventKind(rawValue: rawKind) else {
                    return ControlResponse(ok: false, error: ControlEventRequestError.invalidKind(rawKind))
                }
                parsedKinds.insert(kind)
            }
        }
        let kinds: Set<ControlEventKind>? = parsedKinds.isEmpty ? nil : parsedKinds
        return actions.readEvents(ControlEventReadOptions(cursor: cursor, kinds: kinds, limit: limit))
    }

    private func dispatchSessionCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionNew:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            // The anchor sid carries its own workspace, so placement can't also name one.
            if args?.after != nil || args?.before != nil, args?.workspace != nil || args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "session.new takes --after/--before or a workspace, not both")
            }
            if args?.workspace != nil, args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "use either --workspace or --workspace-name, not both")
            }
            if args?.createWorkspace == true, args?.workspaceName == nil {
                return ControlResponse(ok: false, error: "--create-workspace requires --workspace-name")
            }
            // --wait holds the surface after the command exits, so it is meaningless without a command.
            if args?.wait == true, args?.command == nil {
                return ControlResponse(ok: false, error: "--wait requires --command")
            }
            return actions.createSession(ControlSessionCreateOptions(
                window: args?.window,
                cwd: args?.cwd,
                workspace: args?.workspace,
                workspaceName: args?.workspaceName,
                createWorkspace: args?.createWorkspace,
                command: args?.command,
                wait: args?.wait,
                name: args?.name,
                after: args?.after,
                before: args?.before,
                noSelect: args?.noSelect == true
            ))
        case .sessionDuplicate:
            // no options: the source session names its own workspace AND its cwd, so a duplicate is fully
            // described by the target. The GUI half is the sidebar row's "Duplicate".
            return actions.duplicateSession(request.target, window: request.args?.window)
        case .sessionSelect:
            return actions.selectSession(request.target, window: request.args?.window)
        case .sessionGo:
            guard let dir = (request.args?.to).flatMap(SessionNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "session.go requires --to next|prev|first|last|next-attention|prev-attention")
            }
            return actions.goSession(window: request.args?.window, direction: dir)
        case .sessionClose:
            if let targets = request.args?.targets {
                guard !targets.isEmpty else {
                    return ControlResponse(ok: false, error: "session.close requires at least one --target")
                }
                return actions.closeSessions(targets, window: request.args?.window)
            }
            return actions.closeSession(request.target, window: request.args?.window)
        case .sessionRename:
            guard let name = request.args?.name else {
                return ControlResponse(ok: false, error: "session.rename requires a name")
            }
            return actions.renameSession(request.target, window: request.args?.window, name: name)
        case .sessionReveal:
            return actions.revealSession(request.target, window: request.args?.window)
        case .sessionMove:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            // Placement mode: the anchor sid self-identifies the destination workspace, so it's
            // mutually exclusive with --to and with a workspace parameter.
            if let anchor = args?.after ?? args?.before {
                if args?.to != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or --to, not both")
                }
                if args?.workspace != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or a workspace, not both")
                }
                let move = ControlSessionMove.place(anchor: anchor, after: args?.after != nil)
                if let targets = args?.targets {
                    return dispatchSessionMove(targets: targets, window: args?.window, move: move)
                }
                return actions.moveSession(request.target, window: args?.window, move: move)
            }
            if args?.to != nil && args?.workspace != nil {
                return ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both")
            }
            if let to = args?.to {
                guard let direction = ReorderDirection(rawValue: to) else {
                    return ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom")
                }
                if args?.targets != nil {
                    return ControlResponse(ok: false, error: "session.move --target can be repeated only with a workspace or --after/--before")
                }
                return actions.moveSession(request.target, window: args?.window, move: .reorder(direction))
            }
            guard let workspace = args?.workspace else {
                return ControlResponse(ok: false, error: "session.move requires --to or a workspace")
            }
            let move = ControlSessionMove.workspace(workspace)
            if let targets = args?.targets {
                return dispatchSessionMove(targets: targets, window: args?.window, move: move)
            }
            return actions.moveSession(request.target, window: args?.window, move: move)
        case .sessionFlag:
            return actions.setSessionFlag(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionSeen:
            return actions.markSessionSeen(request.target, window: request.args?.window)
        case .sessionStatus:
            guard let status = AgentStatus(rawValue: request.args?.status ?? "") else {
                return ControlResponse(ok: false, error: "invalid status")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color (expected #rrggbb)")
            }
            var shape: StatusShape?
            if let raw = request.args?.shape {
                guard let parsed = StatusShape(rawValue: raw) else {
                    return ControlResponse(ok: false, error: "invalid shape: \(raw) (\(StatusShape.validNamesList))")
                }
                shape = parsed
            }
            let pane: StatusPane?
            switch parsePane(request.args?.pane) {
            case .pane(let parsed): pane = parsed
            case .rejected(let rejection): return rejection
            }
            let update = ControlSessionStatusUpdate(status: status, blink: request.args?.blink,
                                                    autoReset: request.args?.autoReset,
                                                    sound: request.args?.sound, color: request.args?.color,
                                                    shape: shape,
                                                    pane: pane, paneID: request.args?.paneID)
            return actions.setSessionStatus(request.target, window: request.args?.window, update: update)
        case .sessionRestore:
            return dispatchSessionRestore(request)
        default:
            preconditionFailure("unexpected session command: \(request.cmd.rawValue)")
        }
    }

    /// `session.restore`: parse the `set`|`none`|`clear` mode into a `ControlRestoreOverride` and the pane
    /// selector into a `StatusPane`, then hand both to the host. A pinned command is validated but NEVER
    /// rewritten — it is a shell line, so metacharacters are the point; it is rejected only for being
    /// absent, carrying control characters, or exceeding the storage cap. An EMPTY command means the same
    /// pinned-to-nothing state as `none`. `paneID` rides through opaquely (no session here to resolve it).
    private func dispatchSessionRestore(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let pin: ControlRestoreOverride
        switch args?.mode ?? "" {
        case "set":
            guard let command = args?.command else {
                return ControlResponse(ok: false, error: "session.restore set requires a command")
            }
            // a control character would smuggle an extra line (or an escape sequence) into the shell the
            // override is typed into, so the whole class is rejected — tab included.
            guard !CommandRestore.hasControlCharacter(command) else {
                return ControlResponse(ok: false, error: "command must not contain control characters")
            }
            guard command.utf8.count <= ControlRestoreOverride.maxCommandBytes else {
                return ControlResponse(ok: false,
                                       error: "command too long (max \(ControlRestoreOverride.maxCommandBytes) bytes)")
            }
            pin = .pin(command)
        case "none":
            pin = .pinNone
        case "clear":
            pin = .unpin
        default:
            return ControlResponse(ok: false,
                                   error: "invalid restore mode: \(args?.mode ?? "") (set|none|clear)")
        }
        let pane: StatusPane?
        switch parsePane(args?.pane) {
        case .pane(let parsed): pane = parsed
        case .rejected(let rejection): return rejection
        }
        let update = ControlSessionRestoreUpdate(pin: pin, pane: pane, paneID: args?.paneID)
        return actions.setSessionRestore(request.target, window: args?.window, update: update)
    }

    /// The outcome of parsing a `--pane` selector: the pane (nil when the selector was absent), or the
    /// rejection response the arm returns as-is. Generic over the pane type, so the role selector and the
    /// overlay selector differ only in which enum they parse into and which rejection they carry.
    private enum PaneSelection<Pane> {
        case pane(Pane?)
        case rejected(ControlResponse)
    }

    /// Non-nil when `text` carries a NUL: libghostty's key-text field is NUL-terminated and slices at the
    /// first zero, dropping the run's tail while the Return after it still submits the shortened line (#455).
    private func nulRejection(_ text: String) -> ControlResponse? {
        guard text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return ControlResponse(ok: false, error: "text must not contain a NUL byte")
    }

    /// The shared `--pane` selector: nil when absent, the parsed pane when `parse` accepts it, and `error`
    /// as the pinned rejection otherwise. No live session needed either way.
    private func parsePane<Pane>(_ raw: String?, error: String,
                                 parse: (String) -> Pane?) -> PaneSelection<Pane> {
        guard let raw else { return .pane(nil) }
        guard let parsed = parse(raw) else { return .rejected(ControlResponse(ok: false, error: error)) }
        return .pane(parsed)
    }

    /// The role selector (`session.status`, `session.restore`). It accepts role and position aliases; the
    /// stable rejection names the canonical `left|right|scratch` read-back values.
    private func parsePane(_ raw: String?) -> PaneSelection<StatusPane> {
        parsePane(raw, error: "--pane must be left, right, or scratch") { StatusPane(controlName: $0) }
    }

    /// The `session.overlay.*` selector (`.open`/`.close`/`.result`/`.copy`/`.text`): absent keeps the
    /// session-wide overlay,
    /// `left`/`right` (and their `primary`/`split` aliases) scope to one pane, `scratch` is rejected — there
    /// being no scratch pane to cover.
    private func parseOverlayPane(_ raw: String?) -> PaneSelection<OverlayPane> {
        parsePane(raw, error: PaneOverlayError.invalidPane) { OverlayPane(controlName: $0) }
    }

    private func dispatchSessionMove(targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse {
        guard let first = targets.first else {
            return ControlResponse(ok: false, error: "session.move requires at least one --target")
        }
        if targets.count == 1 {
            return actions.moveSession(first, window: window, move: move)
        }
        return actions.moveSessions(targets, window: window, move: move)
    }

    private func dispatchWorkspaceCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .workspaceNew:
            return actions.createWorkspace(window: request.args?.window, name: request.args?.name,
                                           collapsed: request.args?.collapsed ?? false)
        case .workspaceSelect:
            return actions.selectWorkspace(request.target, window: request.args?.window)
        case .workspaceGo:
            guard let dir = (request.args?.to).flatMap(WorkspaceNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "workspace.go requires --to next|prev")
            }
            return actions.goWorkspace(window: request.args?.window, direction: dir)
        case .workspaceRename:
            guard let name = request.args?.name?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "workspace.rename requires a name")
            }
            return actions.renameWorkspace(request.target, window: request.args?.window, name: name)
        case .workspaceDelete:
            return actions.deleteWorkspace(request.target, window: request.args?.window)
        case .workspaceMove:
            guard let to = request.args?.to else {
                return ControlResponse(ok: false, error: "workspace.move requires --to")
            }
            guard let direction = ReorderDirection(rawValue: to) else {
                return ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom")
            }
            return actions.moveWorkspace(request.target, window: request.args?.window, direction: direction)
        case .workspaceFocus:
            // parsed + rejected BEFORE the host runs, so an unknown mode can never half-apply; the
            // accepted list is derived from `allCases`, so it cannot go stale when a mode is added.
            let raw = request.args?.mode ?? ControlWorkspaceFocusMode.toggle.rawValue
            guard let mode = ControlWorkspaceFocusMode(rawValue: raw) else {
                return ControlResponse(ok: false,
                                       error: "invalid focus mode: \(raw) (\(ControlWorkspaceFocusMode.validNamesList))")
            }
            return actions.focusWorkspace(request.target, window: request.args?.window, mode: mode)
        case .workspaceFilter:
            // window-scoped: no workspace target, only the flag. Same on/off/toggle vocabulary and shared
            // parser as `sidebar`, defaulting to `toggle`.
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false,
                                       error: "invalid workspace filter mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setWorkspaceFilter(window: request.args?.window, mode: mode)
        case .workspaceCollapse:
            return actions.setWorkspaceExpansion(request.target, window: request.args?.window, expanded: false)
        case .workspaceExpand:
            return actions.setWorkspaceExpansion(request.target, window: request.args?.window, expanded: true)
        default:
            preconditionFailure("unexpected workspace command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionSurfaceCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .sessionSplit:
            let axis: SplitAxis?
            if let raw = request.args?.axis {
                guard let parsed = SplitAxis(rawValue: raw) else {
                    return ControlResponse(ok: false, error: "invalid split axis: \(raw) (vertical|horizontal)")
                }
                axis = parsed
            } else {
                axis = nil
            }
            return actions.splitSession(request.target, window: request.args?.window,
                                        mode: request.args?.mode, axis: axis)
        case .sessionSplitClose:
            return actions.closeSessionSplit(request.target, window: request.args?.window)
        case .sessionSwap:
            return await actions.swapSessionPanes(request.target, window: request.args?.window)
        case .sessionScratch:
            return actions.scratchSession(request.target, window: request.args?.window, mode: request.args?.mode,
                                          command: request.args?.command)
        case .sessionFocus:
            return actions.focusSessionPane(request.target, window: request.args?.window, pane: request.args?.pane)
        case .sessionResize:
            switch (request.args?.ratio, request.args?.ratioDelta) {
            case (nil, nil):
                return ControlResponse(ok: false, error: "session.resize requires --split-ratio, --grow-left, or --grow-right")
            case (.some, .some):
                return ControlResponse(ok: false, error: "session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right")
            case (.some(let ratio), nil):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .ratio(ratio))
            case (nil, .some(let delta)):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .delta(delta))
            }
        case .surfaceZoom:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false, error: "invalid surface zoom mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSurfaceZoom(request.target, window: request.args?.window, mode: mode)
        case .surfaceCursor:
            return actions.readSurfaceCursor(request.target, window: request.args?.window)
        case .sessionType:
            guard let text = request.args?.text else {
                return ControlResponse(ok: false, error: "session.type requires text")
            }
            if let rejection = nulRejection(text) { return rejection }
            return await actions.typeSession(request.target, window: request.args?.window,
                                             options: ControlSessionTypeOptions(
                                                text: text,
                                                select: request.args?.select ?? false,
                                                pane: request.args?.pane
                                             ))
        case .sessionCopy:
            return actions.copySessionSelection(request.target, window: request.args?.window)
        case .sessionPaste:
            return actions.pasteSession(request.target, window: request.args?.window)
        case .sessionSelectAll:
            return actions.selectAllSession(request.target, window: request.args?.window)
        case .sessionSearch:
            return await actions.searchSession(request.target, window: request.args?.window,
                                               text: request.args?.text, to: request.args?.to)
        case .sessionOverlayOpen:
            guard let command = request.args?.command, !command.isEmpty else {
                return ControlResponse(ok: false, error: "session.overlay.open requires a command")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            let pane: OverlayPane?
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let parsed): pane = parsed
            }
            if pane != nil, request.args?.sizePercent != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict)
            }
            if let percent = request.args?.sizePercent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.open: --size-percent must be 1...100")
            }
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: request.args?.cwd,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false,
                                                pane: pane
                                              ))
        case .sessionOverlayClose:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.closeSessionOverlay(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayResize:
            // pane overlays are always full, so ANY `--pane` is refused here, valid spelling or not.
            if request.args?.pane != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.resizeUnsupported)
            }
            let wantsFull = request.args?.full == true
            let percent = request.args?.sizePercent
            if wantsFull, percent != nil {
                return ControlResponse(ok: false, error: "session.overlay.resize: --full is mutually exclusive with --size-percent")
            }
            if !wantsFull, percent == nil {
                return ControlResponse(ok: false, error: "session.overlay.resize requires --size-percent or --full")
            }
            if let percent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100")
            }
            return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                sizePercent: wantsFull ? nil : percent)
        case .sessionOverlayResult:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.sessionOverlayResult(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayCopy:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.copySessionOverlaySelection(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayText:
            return dispatchSessionOverlayText(request)
        case .sessionBackground:
            return dispatchSessionBackground(request)
        case .sessionText:
            return dispatchSessionText(request)
        default:
            preconditionFailure("unexpected session surface command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchAppCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .fontInc:
            return actions.font(request.target, window: request.args?.window,
                                pane: request.args?.pane, action: "increase_font_size:1")
        case .fontDec:
            return actions.font(request.target, window: request.args?.window,
                                pane: request.args?.pane, action: "decrease_font_size:1")
        case .fontReset:
            return actions.font(request.target, window: request.args?.window,
                                pane: request.args?.pane, action: "reset_font_size")
        case .quick:
            return actions.setQuickTerminal(mode: request.args?.mode)
        case .keymapReload:
            return actions.reloadKeymap()
        case .keymapList:
            return actions.listKeymap()
        case .version:
            return actions.appIdentity()
        case .configReload:
            return actions.reloadGhosttyConfig()
        case .notify:
            guard let body = request.args?.body, !body.isEmpty else {
                return ControlResponse(ok: false, error: "notify requires a body")
            }
            return actions.sendNotification(request.target, window: request.args?.window,
                                            title: request.args?.title, body: body)
        case .themeSet:
            return actions.setTheme(args: request.args)
        case .themeList:
            return actions.listThemes()
        case .sidebar:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarVisibility(mode)
        case .sidebarMode:
            guard let mode = ControlSidebarViewMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarViewMode(mode)
        case .sidebarExpand:
            return actions.expandSidebar(window: request.args?.window)
        case .sidebarCollapse:
            return actions.collapseSidebar(window: request.args?.window)
        case .restoreClear:
            return actions.clearRestoreCommands()
        case .restoreCapture:
            return actions.captureRestoreCommands()
        default:
            preconditionFailure("unexpected app command: \(request.cmd.rawValue)")
        }
    }

    /// The quick-terminal input/read commands, `async` because the app side polls briefly for the surface
    /// to mount + realize after `quick show` — the same realize-wait that makes `session.type`/`session.text`
    /// async.
    private func dispatchQuickCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .quickType:
            guard let text = request.args?.text else {
                return ControlResponse(ok: false, error: "quick.type requires text")
            }
            if let rejection = nulRejection(text) { return rejection }
            return await actions.typeQuick(text: text)
        case .quickText:
            let all = request.args?.all ?? false
            let lines = request.args?.lines
            if all, lines != nil {
                return ControlResponse(ok: false, error: "use either --all or --lines, not both")
            }
            if let lines, lines <= 0 {
                return ControlResponse(ok: false, error: "--lines must be greater than 0")
            }
            return await actions.readQuickText(all: all, lines: lines)
        default:
            preconditionFailure("unexpected quick command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionBackground(_ request: ControlRequest) -> ControlResponse {
        // The args bag is normalized into the option struct here so the app-side adapter stays a small
        // fixed-arity signature (swiftlint function_parameter_count) rather than a 10-parameter dispatch.
        if let fit = request.args?.fit, !WatermarkConfig.isValidFit(fit) {
            return ControlResponse(ok: false, error: "invalid fit: \(fit) (contain|cover|stretch|none)")
        }
        if let position = request.args?.position, !WatermarkConfig.isValidPosition(position) {
            return ControlResponse(ok: false, error: "invalid position: \(position)")
        }
        if let opacity = request.args?.opacity, !WatermarkConfig.isValidOpacity(opacity) {
            return ControlResponse(ok: false, error: "invalid opacity: \(opacity) (0.0-1.0)")
        }
        let watermark: BackgroundWatermark?
        switch request.args?.mode {
        case "image":
            guard let path = request.args?.path, !path.isEmpty else {
                return ControlResponse(ok: false, error: "session.background image requires a path")
            }
            guard WatermarkConfig.isValidImagePath(path) else {
                return ControlResponse(ok: false, error: "image path must not contain control characters")
            }
            watermark = BackgroundWatermark(kind: .image, imagePath: path, opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)),
                                            repeats: request.args?.repeats)
        case "text":
            guard let text = request.args?.text, !text.isEmpty else {
                return ControlResponse(ok: false, error: "session.background text requires text")
            }
            guard text.count <= WatermarkConfig.maxTextLength else {
                return ControlResponse(ok: false,
                                       error: "session.background text too long (max \(WatermarkConfig.maxTextLength) characters)")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .text, text: text, colorHex: request.args?.color,
                                            opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)))
        case "color":
            // No per-call opacity: a solid color honors the window translucency set in Settings, applied at
            // emit time via `WatermarkConfig.overlayText(windowOpacity:)` (see `GhosttySurfaceView`).
            guard let color = request.args?.color, !color.isEmpty else {
                return ControlResponse(ok: false, error: "session.background color requires a color")
            }
            guard WatermarkConfig.isValidColorHex(color) else {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .color, colorHex: color)
        case "clear", .none:
            watermark = nil
        default:
            return ControlResponse(ok: false,
                                   error: "invalid background mode: \(request.args?.mode ?? "") (image|text|color|clear)")
        }
        return actions.setSessionBackground(request.target, window: request.args?.window,
                                            options: ControlSessionBackgroundOptions(watermark: watermark))
    }

    /// How much of a buffer a read covers, or the rejection its arm returns as-is. Shared by `session.text`
    /// and `session.overlay.text` so the two cannot drift; an unchecked nonpositive `lines` would fall
    /// through to the full buffer.
    private enum BufferExtent {
        case extent(all: Bool, lines: Int?)
        case rejected(ControlResponse)
    }

    private func parseBufferExtent(_ args: ControlArgs?) -> BufferExtent {
        let all = args?.all ?? false
        let lines = args?.lines
        if all, lines != nil {
            return .rejected(ControlResponse(ok: false, error: "use either --all or --lines, not both"))
        }
        if let lines, lines <= 0 {
            return .rejected(ControlResponse(ok: false, error: "--lines must be greater than 0"))
        }
        return .extent(all: all, lines: lines)
    }

    private func dispatchSessionText(_ request: ControlRequest) -> ControlResponse {
        switch parseBufferExtent(request.args) {
        case .rejected(let response): return response
        case .extent(let all, let lines):
            return actions.readSessionText(request.target, window: request.args?.window,
                                           options: ControlSessionTextOptions(pane: request.args?.pane,
                                                                              paneID: request.args?.paneID,
                                                                              all: all,
                                                                              lines: lines))
        }
    }

    /// The extent is checked before the pane, so the same flags produce the same first error here and on
    /// `session.text`.
    private func dispatchSessionOverlayText(_ request: ControlRequest) -> ControlResponse {
        let all: Bool
        let lines: Int?
        switch parseBufferExtent(request.args) {
        case .rejected(let response): return response
        case .extent(let parsedAll, let parsedLines):
            all = parsedAll
            lines = parsedLines
        }
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let pane):
            return actions.readSessionOverlayText(request.target, window: request.args?.window,
                                                  options: ControlSessionOverlayTextOptions(pane: pane,
                                                                                            all: all,
                                                                                            lines: lines))
        }
    }

    private func dispatchWindowCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .windowNew:
            return await actions.windowNew(name: request.args?.name, minimized: request.args?.minimized ?? false)
        case .windowList:
            return actions.windowList()
        case .windowSelect:
            return await actions.windowSelect(request.target)
        case .windowClose:
            return await actions.windowClose(request.target)
        case .windowRename:
            guard let name = request.args?.name?.trimmedOrNil else {
                return ControlResponse(ok: false, error: "window.rename requires a name")
            }
            return actions.windowRename(request.target, name: name)
        case .windowDelete:
            return actions.windowDelete(request.target)
        case .windowResize:
            guard let width = request.args?.width, let height = request.args?.height,
                  width > 0, height > 0 else {
                return ControlResponse(ok: false, error: "window.resize requires positive width and height")
            }
            return actions.windowResize(request.target, width: width, height: height)
        case .windowMove:
            guard let x = request.args?.x, let y = request.args?.y else {
                return ControlResponse(ok: false, error: "window.move requires x and y")
            }
            return actions.windowMove(request.target, x: x, y: y, display: request.args?.display)
        case .windowZoom:
            return actions.windowZoom(request.target)
        case .windowFullscreen:
            return actions.windowFullscreen(request.target)
        case .windowMinimize:
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false, error: "invalid window minimize mode: \(request.args?.mode ?? "toggle")")
            }
            return await actions.windowMinimize(request.target, mode: mode)
        default:
            preconditionFailure("unexpected window command: \(request.cmd.rawValue)")
        }
    }

    /// The dashboard overlay is host-free-validated here: an open needs at least one id (or `--mru`) and at
    /// most one font flag, `--close` takes no id/`--mru`/font flag, a `--font-size` must be finite and
    /// positive, `--mru` cannot be combined with explicit ids (but composes with the font flags), and every
    /// id parses as a `DashboardTarget` — a malformed pane suffix fails the whole command here, while a
    /// well-formed ref naming no live pane is an app-side miss.
    /// The 9-cell cap is NOT applied here — the cell unit is a session+pane, so a split session expands to
    /// two cells and the cap counts PANES, which needs the store. That expansion + cap, the dropped-pane
    /// report, target resolution (incl. the `--mru` recency lookup), the surface reparent, and the
    /// per-window controller all live app-side behind `ControlActions.setDashboard`
    /// (`ControlServer.setDashboard`); this forwards the ids as raw strings once their grammar is checked.
    private func dispatchDashboard(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let targets = args?.targets ?? []
        let fontSize = args?.fontSize
        let autoSize = args?.autoSize ?? false
        let mru = args?.mru ?? false

        if args?.close == true {
            guard targets.isEmpty, !mru, fontSize == nil, !autoSize else {
                return ControlResponse(ok: false, error: "dashboard --close takes no ids, --mru, or font options")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: true, fontMode: .untouched, mru: false)
        }

        if fontSize != nil, autoSize {
            return ControlResponse(ok: false, error: "dashboard: --font-size is mutually exclusive with --auto-size")
        }
        if let fontSize, !fontSize.isFinite || fontSize <= 0 {
            return ControlResponse(ok: false, error: "dashboard --font-size must be a positive number")
        }
        let fontMode: DashboardFontMode = autoSize ? .auto : (fontSize.map(DashboardFontMode.fixed) ?? .untouched)
        if mru {
            guard targets.isEmpty else {
                return ControlResponse(ok: false, error: "dashboard --mru cannot be combined with explicit session ids")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: false, fontMode: fontMode, mru: true)
        }
        guard !targets.isEmpty else {
            return ControlResponse(ok: false, error: "dashboard requires at least one session id")
        }
        // grammar only: a malformed pane suffix fails the command here, while a well-formed ref that
        // resolves to nothing is app-side and joins the `unresolved` note instead.
        if let malformed = targets.first(where: { DashboardTarget(rawValue: $0) == nil }) {
            return ControlResponse(
                ok: false,
                error: "dashboard: invalid session id '\(malformed)' — use <id>, <id>:left, or <id>:right")
        }
        return actions.setDashboard(targets: targets, window: args?.window, close: false, fontMode: fontMode, mru: false)
    }
}
