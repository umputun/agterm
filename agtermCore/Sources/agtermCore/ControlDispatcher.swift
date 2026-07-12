import Foundation

/// App-facing operations a host must provide for commands routed through `ControlDispatcher`.
/// The dispatcher owns command parsing and response shape; the host keeps target resolution and
/// platform-specific side effects.
@MainActor
public protocol ControlActions {
    func controlTree(window: String?) -> ControlResponse
    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse
    func selectSession(_ target: String?, window: String?) -> ControlResponse
    func goSession(window: String?, direction: SessionNavigation) -> ControlResponse
    func closeSession(_ target: String?, window: String?) -> ControlResponse
    func closeSessions(_ targets: [String], window: String?) -> ControlResponse
    func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse
    func revealSession(_ target: String?, window: String?) -> ControlResponse
    func createWorkspace(window: String?, name: String?) -> ControlResponse
    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse
    func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse
    func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse
    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse
    func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse
    func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse
    func focusWorkspace(_ target: String?, window: String?, mode: String?) -> ControlResponse
    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse
    func markSessionSeen(_ target: String?, window: String?) -> ControlResponse
    func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) -> ControlResponse
    func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse
    func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse
    func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse
    func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse
    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse
    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse
    func font(_ target: String?, window: String?, pane: String?, action: String) -> ControlResponse
    func reloadKeymap() -> ControlResponse
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
    func closeSessionOverlay(_ target: String?, window: String?) -> ControlResponse
    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse
    func sessionOverlayResult(_ target: String?, window: String?) -> ControlResponse
    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse
    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse
    func windowNew(name: String?) -> ControlResponse
    func windowList() -> ControlResponse
    func windowSelect(_ target: String?) async -> ControlResponse
    func windowClose(_ target: String?) async -> ControlResponse
    func windowRename(_ target: String?, name: String) -> ControlResponse
    func windowDelete(_ target: String?) -> ControlResponse
    func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse
    func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse
    func windowZoom(_ target: String?) -> ControlResponse
    func windowFullscreen(_ target: String?) -> ControlResponse
    func clearRestoreCommands() -> ControlResponse
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

    public init(command: String, cwd: String?, wait: Bool, sizePercent: Int?, backgroundColor: String?,
                follow: Bool = false) {
        self.command = command
        self.cwd = cwd
        self.wait = wait
        self.sizePercent = sizePercent
        self.backgroundColor = backgroundColor
        self.follow = follow
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
    public let all: Bool
    public let lines: Int?

    public init(pane: String?, all: Bool, lines: Int?) {
        self.pane = pane
        self.all = all
        self.lines = lines
    }
}

/// Routes control commands through a host-provided action seam. The dispatcher owns command parsing and
/// response shape; host actions keep target resolution, AppKit state, and terminal-surface side effects.
@MainActor
public struct ControlDispatcher {
    private let actions: any ControlActions

    public init(actions: any ControlActions) {
        self.actions = actions
    }

    public func dispatch(_ request: ControlRequest) async -> ControlResponse? {
        switch request.cmd {
        case .tree:
            return actions.controlTree(window: request.args?.window)
        case .sessionNew, .sessionSelect, .sessionGo, .sessionClose, .sessionRename, .sessionReveal,
                .sessionMove, .sessionFlag, .sessionSeen, .sessionStatus:
            return dispatchSessionCommand(request)
        case .sessionSplit, .sessionScratch, .sessionFocus, .sessionResize, .surfaceZoom, .sessionType,
                .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch, .sessionOverlayOpen,
                .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult, .sessionBackground,
                .sessionText:
            return await dispatchSessionSurfaceCommand(request)
        case .workspaceNew, .workspaceSelect, .workspaceRename, .workspaceDelete,
                .workspaceMove, .workspaceFocus:
            return dispatchWorkspaceCommand(request)
        case .quick, .fontInc, .fontDec, .fontReset, .keymapReload,
                .configReload, .notify, .themeSet, .themeList, .sidebar, .sidebarMode, .sidebarExpand,
                .sidebarCollapse, .restoreClear:
            return dispatchAppCommand(request)
        case .quickType, .quickText:
            return await dispatchQuickCommand(request)
        case .windowNew, .windowList, .windowSelect, .windowClose, .windowRename,
                .windowDelete, .windowResize, .windowMove, .windowZoom, .windowFullscreen:
            return await dispatchWindowCommand(request)
        case .dashboard:
            return dispatchDashboard(request)
        case .debugAppearance:
            // UI-test-only seam handled app-side in `ControlServer` (needs AppKit + `ContentView.isUITestLaunch`).
            return nil
        }
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
            return actions.createSession(ControlSessionCreateOptions(
                window: args?.window,
                cwd: args?.cwd,
                workspace: args?.workspace,
                workspaceName: args?.workspaceName,
                createWorkspace: args?.createWorkspace,
                command: args?.command,
                name: args?.name,
                after: args?.after,
                before: args?.before
            ))
        case .sessionSelect:
            return actions.selectSession(request.target, window: request.args?.window)
        case .sessionGo:
            // unknown/missing `to` is a structured error.
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
            var pane: StatusPane?
            if let rawPane = request.args?.pane {
                guard let parsed = StatusPane(rawValue: rawPane) else {
                    return ControlResponse(ok: false, error: "--pane must be left, right, or scratch")
                }
                pane = parsed
            }
            let update = ControlSessionStatusUpdate(status: status, blink: request.args?.blink,
                                                    autoReset: request.args?.autoReset,
                                                    sound: request.args?.sound, color: request.args?.color, pane: pane)
            return actions.setSessionStatus(request.target, window: request.args?.window, update: update)
        default:
            preconditionFailure("unexpected session command: \(request.cmd.rawValue)")
        }
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
            return actions.createWorkspace(window: request.args?.window, name: request.args?.name)
        case .workspaceSelect:
            return actions.selectWorkspace(request.target, window: request.args?.window)
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
            return actions.focusWorkspace(request.target, window: request.args?.window, mode: request.args?.mode)
        default:
            preconditionFailure("unexpected workspace command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionSurfaceCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .sessionSplit:
            return actions.splitSession(request.target, window: request.args?.window, mode: request.args?.mode)
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
        case .sessionType:
            guard let text = request.args?.text else {
                return ControlResponse(ok: false, error: "session.type requires text")
            }
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
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: request.args?.cwd,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false
                                              ))
        case .sessionOverlayClose:
            return actions.closeSessionOverlay(request.target, window: request.args?.window)
        case .sessionOverlayResize:
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
            return actions.sessionOverlayResult(request.target, window: request.args?.window)
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
        default:
            preconditionFailure("unexpected app command: \(request.cmd.rawValue)")
        }
    }

    /// The quick-terminal input/read commands, `async` because the app side polls briefly for the surface
    /// to mount + realize after `quick show` (the twin of `session.type`/`session.text`, which are async
    /// for the same realize-wait reason).
    private func dispatchQuickCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .quickType:
            guard let text = request.args?.text else {
                return ControlResponse(ok: false, error: "quick.type requires text")
            }
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

    private func dispatchSessionText(_ request: ControlRequest) -> ControlResponse {
        let all = request.args?.all ?? false
        let lines = request.args?.lines
        if all, lines != nil {
            return ControlResponse(ok: false, error: "use either --all or --lines, not both")
        }
        if let lines, lines <= 0 {
            return ControlResponse(ok: false, error: "--lines must be greater than 0")
        }
        return actions.readSessionText(request.target, window: request.args?.window,
                                       options: ControlSessionTextOptions(pane: request.args?.pane,
                                                                          all: all,
                                                                          lines: lines))
    }

    private func dispatchWindowCommand(_ request: ControlRequest) async -> ControlResponse {
        switch request.cmd {
        case .windowNew:
            return actions.windowNew(name: request.args?.name)
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
        default:
            preconditionFailure("unexpected window command: \(request.cmd.rawValue)")
        }
    }

    /// The dashboard overlay is host-free-validated here. The open path needs at least one id (or `--mru`)
    /// and at most one font flag; `--close` takes no id, `--mru`, or font flag; a `--font-size` must be
    /// finite and positive; `--mru` cannot be combined with explicit ids (but composes with the font flags).
    /// The 9-cell cap is NOT applied here: the cell unit is a session+pane, so a split session expands to two
    /// cells and the cap counts PANES — that expansion needs the store, so it lives app-side in
    /// `ControlServer.setDashboard`, which also reports any dropped panes. Target resolution (incl. the
    /// `--mru` recency lookup), the pane expansion + cap, the surface reparent, and the per-window controller
    /// all stay app-side behind `ControlActions.setDashboard`; this only forwards the raw ids.
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
            // --mru supplies the members app-side from the window's recency, so it takes no explicit ids; the
            // font flags still apply.
            guard targets.isEmpty else {
                return ControlResponse(ok: false, error: "dashboard --mru cannot be combined with explicit session ids")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: false, fontMode: fontMode, mru: true)
        }
        guard !targets.isEmpty else {
            return ControlResponse(ok: false, error: "dashboard requires at least one session id")
        }
        return actions.setDashboard(targets: targets, window: args?.window, close: false, fontMode: fontMode, mru: false)
    }
}
