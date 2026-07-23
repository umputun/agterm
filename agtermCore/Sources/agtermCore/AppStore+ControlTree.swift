import Foundation

extension AppStore {
    /// Projects this store's workspace/session model into the control-channel `tree` payload. Foreground
    /// command lookup is supplied by the host because live process inspection is platform-specific.
    public func controlTree(foreground: (Session) -> [String]? = { _ in nil },
                            splitForeground: (Session) -> [String]? = { _ in nil },
                            fontSize: (Session) -> Double? = { _ in nil },
                            splitFontSize: (Session) -> Double? = { _ in nil },
                            scratchFontSize: (Session) -> Double? = { _ in nil },
                            canvasGrid: (Session) -> (cols: Int, rows: Int)? = { _ in nil },
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
                // `overlaySizePercent` (back-compat wire field) derives from `overlaySize`: the percent for
                // a `.percent` floating overlay, omitted for full or cells (and when no overlay is open).
                let overlayPercent: Int? = if session.overlayActive,
                    case .percent(let percent) = session.overlaySize { percent } else { nil }
                // the REQUESTED grid rides the node only for a cells-mode overlay (nil for percent/full/none).
                let overlayCols: Int?
                let overlayRows: Int?
                if session.overlayActive, case .cells(let cols, let rows) = session.overlaySize {
                    overlayCols = cols
                    overlayRows = rows
                } else {
                    overlayCols = nil
                    overlayRows = nil
                }
                // the REALIZED grid (any floating overlay) exposes a clamp/drift; the anchor rides ANY open
                // overlay incl. full (Decision 2 — anchor is always reported while an overlay is up).
                let overlayColsApplied = session.floatingOverlayActive ? session.overlayAppliedCols : nil
                let overlayRowsApplied = session.floatingOverlayActive ? session.overlayAppliedRows : nil
                let overlayAnchor = session.overlayActive ? session.overlayAnchor.rawValue : nil
                // the terminal content area (overlay canvas) in cells at the base font — supplied app-side
                // (the host-free tree can't read a surface), omitted when no surface is realized.
                let canvas = canvasGrid(session)
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
                                          overlaySizePercent: overlayPercent,
                                          overlayCols: overlayCols, overlayRows: overlayRows,
                                          overlayColsApplied: overlayColsApplied,
                                          overlayRowsApplied: overlayRowsApplied, overlayAnchor: overlayAnchor,
                                          scratch: session.scratchActive, flagged: session.flagged,
                                          commandWait: (session.initialCommand != nil && session.commandWait) ? true : nil,
                                          foreground: foreground(session),
                                          splitForeground: splitForeground(session),
                                          // the PERSISTED overrides, never the transient pending payloads,
                                          // so a read after one fired still reports what stays pinned.
                                          restoreCommand: session.restoreCommand,
                                          splitRestoreCommand: session.splitRestoreCommand, status: status,
                                          statusPane: statusPane,
                                          statusBlink: idle ? nil : (session.agentIndicator.blink ? true : nil),
                                          statusColor: idle ? nil : session.agentIndicator.color,
                                          background: session.backgroundWatermark,
                                          unseen: session.unseenCount > 0 ? session.unseenCount : nil,
                                          fontSize: fontSize(session),
                                          splitFontSize: splitFontSize(session),
                                          scratchFontSize: scratchFontSize(session),
                                          surfaces: surfaces,
                                          canvasCols: canvas?.cols, canvasRows: canvas?.rows)
            }
            return ControlWorkspaceNode(id: workspace.id.uuidString, name: workspace.name,
                                        active: workspace.id == activeWorkspaceID,
                                        focused: workspace.id == focusedWorkspaceID ? true : nil,
                                        collapsed: workspace.isExpanded ? nil : true,
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
}
