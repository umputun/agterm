import Foundation

// MARK: - Control tree projection

/// The `tree` response projection. Split out of `AppStore.swift` for the file size limit.
extension AppStore {
    /// Projects this store's workspace/session model into the control-channel `tree` payload. Foreground
    /// command lookup is supplied by the host because live process inspection is platform-specific.
    /// `windowID` names the projected window and is stamped on the tree and on every session node; only the
    /// host knows which window owns a store, so a host-free projection leaves it nil.
    /// `windowName` rides along for `tree --all-windows`'s section headers and is dropped without a `windowID`.
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
                            dashboardFontMode: () -> String? = { nil }, app: AppIdentity? = nil,
                            windowID: String? = nil, windowName: String? = nil) -> ControlTree {
        let activeID = selectedSessionID
        // `currentWorkspaceID`, not the selected session's owner: an EMPTY destination selects nothing, so
        // deriving this from the selection alone made `tree` name the workspace `workspace.go` just left.
        let activeWorkspaceID = currentWorkspaceID
        let nodes = workspaces.map { workspace in
            // one ownership stamp, all or nothing: a projection that names no window cannot say who owns a
            // session, and half an answer is the one a caller would act on wrongly.
            let ownerWorkspaceID = windowID.map { _ in workspace.id.uuidString }
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
                                          hasSplit: session.hasSplit ? true : nil,
                                          splitAxis: session.hasSplit ? session.splitAxis.rawValue : nil,
                                          splitRatio: session.hasSplit ? session.splitRatio : nil,
                                          splitFocused: session.hasSplit ? session.splitFocused : nil,
                                          overlay: session.programOverlayActive,
                                          overlaySizePercent: session.programOverlayActive
                                              ? session.overlaySizePercent : nil,
                                          paneOverlays: paneOverlays(session),
                                          hud: hudNode(session),
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
                                          statusChangedAt: idle ? nil : session.statusChangedAt?.timeIntervalSince1970,
                                          background: session.backgroundWatermark,
                                          unseen: session.unseenCount > 0 ? session.unseenCount : nil,
                                          fontSize: fontSize(session),
                                          splitFontSize: splitFontSize(session),
                                          scratchFontSize: scratchFontSize(session),
                                          surfaces: surfaces,
                                          // host-free: `isRealized` is on `TerminalSurface`, so this needs
                                          // no app-side closure like the font sizes above. An empty slot is
                                          // false, not omitted — "no terminal" either way to a caller.
                                          realized: session.surface?.isRealized ?? false,
                                          windowId: windowID,
                                          workspaceId: ownerWorkspaceID)
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
                           pickPending: pickPending(), app: app, windowId: windowID,
                           windowName: windowID == nil ? nil : windowName)
    }

    /// The tree's `paneOverlays`: the panes covered by their own overlay, omitted when neither is.
    private func paneOverlays(_ session: Session) -> [String]? {
        let panes = session.openPaneOverlays.map(\.rawValue)
        return panes.isEmpty ? nil : panes
    }

    /// The tree's `hud`: the live panel's spec carrying the slot's EFFECTIVE size on BOTH axes and the
    /// effective position, omitted when no HUD occupies the slot.
    private func hudNode(_ session: Session) -> ControlHudNode? {
        guard session.hudActive, let spec = session.hudSpec else { return nil }
        return ControlHudNode(message: spec.message, detail: spec.detail,
                              spinner: spec.spinner?.rawValue ?? HudSpinner.noneName,
                              backgroundColor: spec.backgroundColor, textColor: spec.textColor,
                              sizePercent: session.overlaySizePercent,
                              heightPercent: session.hudHeightPercent, position: spec.position.rawValue)
    }
}
