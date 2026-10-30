import Foundation

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
                .sessionReveal, .sessionMove, .sessionFlag, .sessionContext, .sessionSeen, .sessionStatus,
                .sessionRestore:
            return await dispatchSessionCommand(request)
        case .sessionTint, .workspaceTint:
            return dispatchTint(request)
        case .sessionRestart:
            return await dispatchSessionRestart(request)
        case .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionLead, .sessionScratch, .sessionFocus,
                .sessionResize, .surfaceZoom, .surfaceCursor, .sessionType,
                .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch, .sessionOverlayOpen,
                .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayReload, .sessionOverlayNavigate,
                .sessionOverlayResult, .sessionOverlaySubmit, .sessionOverlayCopy, .sessionOverlayText,
                .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle,
                .sessionBackground, .sessionText:
            return await dispatchSessionSurfaceCommand(request)
        case .sessionOverlayJobRun, .sessionOverlayPageServe:
            return dispatchSessionOverlayCommand(request)
        case .sessionCompanionNew, .sessionCompanionPage, .sessionCompanionDuplicate, .sessionCompanionPageAttach, .sessionCollapse, .sessionExpand:
            return await dispatchCompanionCommand(request)
        case .workspaceNew, .workspaceSelect, .workspaceGo, .workspaceRename, .workspaceDelete,
                .workspaceMove, .workspaceFocus, .workspaceFilter, .workspaceCollapse, .workspaceExpand,
                .workspaceFlag:
            return dispatchWorkspaceCommand(request)
        case .quick, .fontInc, .fontDec, .fontReset, .keymapReload, .keymapList, .keymapRun,
                .configReload, .notify, .themeSet, .themeList, .sidebar, .sidebarMode, .sidebarFlaggedLayout,
                .sidebarExpand, .sidebarCollapse, .sidebarWidth, .restoreClear, .restoreCapture, .version:
            return dispatchAppCommand(request)
        case .restoreMode, .zmxList, .zmxPrune, .zmxKill, .zmxReset, .zmxTree, .zmxAttach, .zmxAttachGroup, .zmxPresent, .zmxScreen:
            return await dispatchZmxCommand(request)
        case .hooksReload, .hooksList:
            return dispatchHooksCommand(request)
        case .recentList, .recentOpen, .recentClear:
            return dispatchRecentCommand(request)
        case .browserClear, .browserLinks:
            return await dispatchBrowserCommand(request)
        case .quickType, .quickText:
            return await dispatchQuickCommand(request)
        case .windowNew, .windowList, .windowSelect, .windowGo, .windowClose, .windowRename,
                .windowDelete, .windowResize, .windowMove, .windowZoom, .windowFullscreen, .windowMinimize:
            return await dispatchWindowCommand(request)
        case .dashboard:
            return dispatchDashboard(request)
        case .debugAppearance:
            // UI-test-only seam handled app-side in `ControlServer` (needs AppKit + `ContentView.isUITestLaunch`).
            return nil
        case .pickOpen, .pickResult, .pickCancel:
            return dispatchPickCommand(request)
        case .askOpen, .askResult, .askCancel:
            return dispatchAskCommand(request)
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

    private func dispatchSessionCommand(_ request: ControlRequest) async -> ControlResponse {
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
            let tint: SidebarTint?
            switch Self.creationTint(args) {
            case .success(let value): tint = value
            case .failure(let rejection): return ControlResponse(ok: false, error: rejection.message)
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
            ), tint: tint)
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
            let window = request.args?.window
            let undoable = request.args?.undoable == true
            if let targets = request.args?.targets {
                guard !targets.isEmpty else {
                    return ControlResponse(ok: false, error: "session.close requires at least one --target")
                }
                return undoable ? actions.closeSessions(targets, window: window, undoable: true)
                    : actions.closeSessions(targets, window: window)
            }
            return undoable ? actions.closeSession(request.target, window: window, undoable: true)
                : actions.closeSession(request.target, window: window)
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
            return dispatchSessionFlag(request)
        case .sessionContext:
            return dispatchSessionContext(request)
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
            return await actions.setSessionStatus(request.target, window: request.args?.window, update: update)
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

    /// `session.restart`: the line is a shell line and is never rewritten; an absent one asks the host to
    /// replay the pane's foreground program. A pane must be named, by token or by role, because a default
    /// would restart a shell the caller never addressed.
    private func dispatchSessionRestart(_ request: ControlRequest) async -> ControlResponse {
        let args = request.args
        let command = args?.command
        if let command {
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                return ControlResponse(ok: false, error: "session.restart takes a non-empty command, or none to replay")
            }
            guard !CommandRestore.hasControlCharacter(command) else {
                return ControlResponse(ok: false, error: "command must not contain control characters")
            }
            guard command.utf8.count <= ControlSessionRestartOptions.maxCommandBytes else {
                return ControlResponse(ok: false, error: "command too long (max "
                    + "\(ControlSessionRestartOptions.maxCommandBytes) bytes)")
            }
        }
        let pane: StatusPane?
        switch parsePane(args?.pane) {
        case .pane(let parsed): pane = parsed
        case .rejected(let rejection): return rejection
        }
        guard pane != .scratch else {
            return ControlResponse(ok: false, error: "session.restart does not address the scratch pane")
        }
        let paneID = args?.paneID.flatMap { $0.isEmpty ? nil : $0 }
        guard pane != nil || paneID != nil else {
            return ControlResponse(ok: false, error: "session.restart requires --pane-id or --pane")
        }
        return await actions.restartSessionPane(request.target, window: args?.window, options: .init(
            command: command, pane: pane, paneID: paneID))
    }

    /// Non-nil when `text` carries a NUL: libghostty's key-text field is NUL-terminated and slices at the
    /// first zero, dropping the run's tail while the Return after it still submits the shortened line (#455).
    private func nulRejection(_ text: String) -> ControlResponse? {
        guard text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return ControlResponse(ok: false, error: "text must not contain a NUL byte")
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
            switch Self.creationTint(request.args) {
            case .failure(let rejection):
                return ControlResponse(ok: false, error: rejection.message)
            case .success(let tint):
                return actions.createWorkspace(window: request.args?.window, name: request.args?.name,
                                               collapsed: request.args?.collapsed ?? false, tint: tint)
            }
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
        case .workspaceFlag:
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false,
                                       error: "invalid workspace flag mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setWorkspaceFlag(request.target, window: request.args?.window, mode: mode)
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
        case .sessionLead:
            switch parseSurfacePane(request.args?.pane) {
            case .pane(let pane): return actions.takeSessionLead(request.target, window: request.args?.window, pane: pane)
            case .rejected(let rejection): return rejection
            }
        case .sessionScratch:
            return actions.scratchSession(request.target, window: request.args?.window, mode: request.args?.mode,
                                          command: request.args?.command, follow: request.args?.follow == true)
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
            return actions.readSurfaceCursor(request.target, window: request.args?.window,
                                             paneID: request.args?.paneID)
        case .sessionType:
            guard let text = request.args?.text else {
                return ControlResponse(ok: false, error: "session.type requires text")
            }
            if let rejection = nulRejection(text) { return rejection }
            let pane: StatusPane?
            switch parseSurfacePane(request.args?.pane) {
            case .pane(let parsed): pane = parsed
            case .rejected(let rejection): return rejection
            }
            return await actions.typeSession(request.target, window: request.args?.window,
                                             options: ControlSessionTypeOptions(
                                                text: text,
                                                select: request.args?.select ?? false,
                                                pane: pane,
                                                paneID: request.args?.paneID
                                             ))
        case .sessionCopy:
            return actions.copySessionSelection(request.target, window: request.args?.window)
        case .sessionPaste:
            switch parsePane(request.args?.pane) {
            case .pane(let parsed):
                return actions.pasteSession(request.target, window: request.args?.window, pane: parsed)
            case .rejected(let rejection): return rejection
            }
        case .sessionSelectAll:
            return actions.selectAllSession(request.target, window: request.args?.window)
        case .sessionSearch:
            return await actions.searchSession(request.target, window: request.args?.window,
                                               text: request.args?.text, to: request.args?.to)
        case .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayReload,
             .sessionOverlayNavigate, .sessionOverlayResult, .sessionOverlaySubmit, .sessionOverlayCopy,
             .sessionOverlayText, .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle:
            return dispatchSessionOverlayCommand(request)
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
            return dispatchFont(request, action: "increase_font_size:1")
        case .fontDec:
            return dispatchFont(request, action: "decrease_font_size:1")
        case .fontReset:
            return dispatchFont(request, action: "reset_font_size")
        case .quick:
            return actions.setQuickTerminal(mode: request.args?.mode)
        case .keymapReload:
            return actions.reloadKeymap()
        case .keymapList:
            return actions.listKeymap()
        case .keymapRun:
            // matched exactly: trimming here would make a name that differs only by spaces unreachable
            guard let name = request.args?.name, !name.isEmpty else {
                return ControlResponse(ok: false, error: "keymap.run requires a command name")
            }
            return actions.runCustomCommand(name: name, target: request.target, window: request.args?.window)
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
        case .sidebarFlaggedLayout:
            guard let mode = ControlFlaggedLayoutMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false, error: "invalid flagged layout: \(request.args?.mode ?? "toggle")")
            }
            return actions.setFlaggedViewLayout(mode)
        case .sidebarExpand:
            return actions.expandSidebar(window: request.args?.window)
        case .sidebarCollapse:
            return actions.collapseSidebar(window: request.args?.window)
        case .sidebarWidth:
            guard let points = request.args?.sidebarWidth, points.isFinite else {
                return ControlResponse(ok: false, error: "sidebar.width requires a width in points")
            }
            return actions.setSidebarWidth(points, window: request.args?.window)
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
        switch parsePane(request.args?.pane) {
        case .pane(let pane):
            return actions.setSessionBackground(request.target, window: request.args?.window,
                                                options: ControlSessionBackgroundOptions(watermark: watermark, pane: pane))
        case .rejected(let rejection): return rejection
        }
    }

    /// How much of a buffer a read covers, or the rejection its arm returns as-is. Shared by `session.text`
    /// and `session.overlay.text` so the two cannot drift; an unchecked nonpositive `lines` would fall
    /// through to the full buffer.
    enum BufferExtent {
        case extent(all: Bool, lines: Int?)
        case rejected(ControlResponse)
    }

    func parseBufferExtent(_ args: ControlArgs?) -> BufferExtent {
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

    /// The three `font.*` arms share one parse, so their pane vocabulary cannot drift apart.
    private func dispatchFont(_ request: ControlRequest, action: String) -> ControlResponse {
        switch parseSurfacePane(request.args?.pane) {
        case .pane(let pane):
            return actions.font(request.target, window: request.args?.window, pane: pane, action: action)
        case .rejected(let rejection): return rejection
        }
    }

    private func dispatchSessionText(_ request: ControlRequest) -> ControlResponse {
        switch parseBufferExtent(request.args) {
        case .rejected(let response): return response
        case .extent(let all, let lines):
            // the extent is checked first, so an `--all --lines` caller still gets that error before a pane one.
            switch parseSurfacePane(request.args?.pane) {
            case .rejected(let rejection): return rejection
            case .pane(let pane):
                return actions.readSessionText(request.target, window: request.args?.window,
                                               options: ControlSessionTextOptions(pane: pane,
                                                                                  paneID: request.args?.paneID,
                                                                                  all: all,
                                                                                  lines: lines))
            }
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
        case .windowGo:
            guard let dir = (request.args?.to).flatMap(WorkspaceNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "window.go requires --to next|prev")
            }
            return actions.windowGo(direction: dir)
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
}
