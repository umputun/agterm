import Foundation

extension AppStore {
    /// Projects this store's workspace/session model into the control-channel `tree` payload. Foreground
    /// command lookup is supplied by the host because live process inspection is platform-specific.
    /// `paneForeground` takes no default on purpose: the argv-shaped compatibility overload defaults every
    /// closure, so one here would leave a bare `controlTree()` ambiguous between the two.
    public func controlTree(paneForeground: (Session) -> CommandRestore.PaneForeground?,
                            splitPaneForeground: (Session) -> CommandRestore.PaneForeground? = { _ in nil },
                            liveAttribution: (UUID) -> SessionHost.Attribution? = { _ in nil },
                            liveHostStale: (UUID) -> Bool = { _ in false },
                            fontSize: (Session) -> Double? = { _ in nil },
                            splitFontSize: (Session) -> Double? = { _ in nil },
                            scratchFontSize: (Session) -> Double? = { _ in nil },
                            quickVisible: () -> Bool? = { nil },
                            zoomedSurface: () -> String? = { nil },
                            pickPending: () -> String? = { nil },
                            askPending: () -> String? = { nil },
                            dashboardMembers: () -> [String]? = { nil },
                            dashboardHighlighted: () -> String? = { nil },
                            dashboardFontSize: () -> Double? = { nil },
                            dashboardFontMode: () -> String? = { nil }, app: AppIdentity? = nil,
                            liveReset: ControlLiveResetReadback? = nil, indexUnsaved: Bool = false,
                            flaggedLayout: FlaggedViewLayout? = nil, htmlZoom: Double? = nil,
                            linkOpenMode: LinkOpenMode? = nil, sidebarDensity: SidebarDensity? = nil) -> ControlTree {
        let activeID = selectedSessionID
        // `currentWorkspaceID`, not the selected session's owner: an EMPTY destination selects nothing, so
        // deriving this from the selection alone made `tree` name the workspace `workspace.go` just left.
        let activeWorkspaceID = currentWorkspaceID
        let nodes = workspaces.map { workspace in
            let parents = Set(workspace.sessions.compactMap(\.parentID))
            let sessions = workspace.sessions.map { session in
                // each closure inspects live processes, so call it once and split the answer in two.
                let mainPane = paneForeground(session)
                let splitPane = splitPaneForeground(session)
                let local = session.remoteHost == nil
                let mainAttribution: SessionHost.Attribution? = local && session.surface?.backedByZmx == true
                    ? liveAttribution(session.paneIdentity) ?? .unknown : nil
                let splitAttribution: SessionHost.Attribution? = local && session.hasSplit && session.splitSurface?.backedByZmx == true
                    ? session.splitPaneIdentity.flatMap(liveAttribution) ?? .unknown : nil
                let mainStale = mainAttribution != nil && liveHostStale(session.paneIdentity)
                let splitStale = splitAttribution != nil && session.splitPaneIdentity.map(liveHostStale) == true
                // one pass per session, ahead of the scratch read-back, so each pane's daemon is checked before its count
                let mailPanes = headless ? [] : livePanes(of: session).map(\.pane)
                let idle = session.agentIndicator.status == .idle
                let status = idle ? nil : session.agentIndicator.status.rawValue
                let statusPane = idle ? nil : session.agentIndicator.statusPane?.rawValue
                let surfaces = TerminalZoomSurface.allCases.compactMap { surface -> ControlSurfaceNode? in
                    guard surface.isAvailable(in: session) else { return nil }
                    let id = TerminalSurfaceID(sessionID: session.id, surface: surface).rawValue
                    let pane = session.paneIdentity(for: surface)
                    let token = surface.surface(in: session)?.paneToken
                        ?? pane.flatMap { session.daemonBackedPanes.contains($0) || mailPanes.contains($0) ? $0.uuidString : nil }
                    return ControlSurfaceNode(id: id, kind: surface.rawValue, active: surface.isActive(in: session),
                                              visible: surface.isVisible(in: session),
                                              backedByZmx: session.zmxBacking(for: surface),
                                              lead: ZmxLeadBook.shared.role(pane: pane),
                                              reconnect: RemoteReconnectBook.shared.readback(pane: pane), attachEnded: attachEnded(pane),
                                              paneID: token?.isEmpty == false ? token : nil,
                                              pendingMessages: pendingMessages(session, pane: pane, token: token),
                                              remote: remotelyPresented(session, pane: pane))
                }
                return ControlSessionNode(id: session.id.uuidString, name: session.displayName,
                                          cwd: (session.content == .page ? parent(of: session) : nil)?.effectiveCwd
                                              ?? session.effectiveCwd, title: session.oscTitle,
                                          active: session.id == activeID,
                                          split: session.isSplit, hasSplit: session.hasSplit ? true : nil,
                                          backedByZmx: session.allPanesBackedByZmx,
                                          splitAxis: session.hasSplit ? session.splitAxis.rawValue : nil,
                                          splitRatio: session.hasSplit ? session.splitRatio : nil,
                                          splitFocused: session.hasSplit ? session.splitFocused : nil,
                                          overlay: session.coverOverlayActive,
                                          overlaySizePercent: session.coverOverlayActive
                                              ? session.overlaySizePercent : nil,
                                          overlayWidth: session.overlayContentSize?.width,
                                          overlayHeight: session.overlayContentSize?.height,
                                          paneOverlays: paneOverlays(session), hud: hudNode(session),
                                          ask: session.askPending.map {
                                              ControlSessionAsk(id: $0.id, pane: session.askTargetPane?.rawValue,
                                                                remote: session.askPresentedRemotely ? true : nil,
                                                                replica: session.askReplica ? true : nil)
                                          },
                                          pick: SessionPickBook.shared.node(forSession: session.id),
                                          scratch: session.scratchActive, flagged: session.flagged,
                                          ended: session.ended ? true : nil,
                                          pending: remoteActions?.pendingState(of: session.id),
                                          scratchBacked: isRemoteWindow && session.scratchDaemon != nil ? true : nil,
                                          scratchPaneID: session.scratchDaemon?.identity.uuidString,
                                          scratchPendingMessages: scratchPendingMessages(session),
                                          interactions: interactionNodes(session),
                                          commandWait: (session.initialCommand != nil && session.commandWait) ? true : nil,
                                          splitCommandWait: (session.splitInitialCommand != nil && session.splitCommandWait)
                                              ? true : nil,
                                          foreground: mainPane?.command, splitForeground: splitPane?.command,
                                          foregroundShell: mainPane?.shellName, splitForegroundShell: splitPane?.shellName,
                                          // the PERSISTED overrides, not the transient pending payloads, so
                                          // a read after one fired still reports what stays pinned.
                                          restoreCommand: session.restoreCommand,
                                          splitRestoreCommand: session.splitRestoreCommand, status: status,
                                          statusPane: statusPane,
                                          statusBlink: idle ? nil : (session.agentIndicator.blink ? true : nil),
                                          statusColor: idle ? nil : session.agentIndicator.color,
                                          statusShape: idle ? nil : session.agentIndicator.shape?.rawValue,
                                          statusChangedAt: session.statusChangedAt?.timeIntervalSince1970, activePanes: activePanes(of: session),
                                          background: session.backgroundWatermark,
                                          paneBackgrounds: session.paneBackgrounds.isEmpty ? nil : session.paneBackgrounds,
                                          unseen: session.unseenCount > 0 ? session.unseenCount : nil,
                                          fontSize: fontSize(session),
                                          splitFontSize: splitFontSize(session),
                                          scratchFontSize: scratchFontSize(session),
                                          surfaces: surfaces,
                                          // host-free: `isRealized` is on `TerminalSurface`, so this needs
                                          // no app-side closure like the font sizes above. An empty slot is
                                          // false, not omitted — "no terminal" either way to a caller.
                                          realized: session.surface?.isRealized ?? false,
                                          context: session.effectiveContext, remoteHost: session.remoteHost,
                                          splitCwd: session.hasSplit ? session.cwd(for: .right) : nil,
                                          scratchCwd: session.scratchSurface == nil ? nil : session.cwd(for: .scratch),
                                          liveAttribution: mainAttribution?.rawValue, splitLiveAttribution: splitAttribution?.rawValue,
                                          liveHostStale: mainStale ? true : nil, splitLiveHostStale: splitStale ? true : nil,
                                          presentation: presentationNode(of: session), presenters: presentersNode(of: session),
                                          remoteOverlays: remoteOverlayNodes(of: session),
                                          htmlOverlays: htmlOverlayNodes(session, zoom: htmlZoom),
                                          hiddenOverlays: hiddenOverlaysNode(session),
                                          lastSelectedAt: session.lastSelectedAt?.timeIntervalSince1970,
                                          tint: session.tint?.color.rawValue, tintOn: session.tint?.parts.map(\.rawValue),
                                          parent: session.parentID?.uuidString,
                                          collapsed: !session.isExpanded && parents.contains(session.id) ? true : nil,
                                          content: session.content == .page ? "page" : nil, info: session.effectiveInfo,
                                          remoteSessionID: session.remoteSessionID, followsCompanions: session.parentID == nil && session.remotePresentation?.followsCompanions == true ? true : nil)
            }
            return ControlWorkspaceNode(id: workspace.id.uuidString, name: workspace.name,
                                        active: workspace.id == activeWorkspaceID,
                                        focused: focusedWorkspaceIDs.contains(workspace.id) ? true : nil,
                                        collapsed: workspace.isExpanded ? nil : true,
                                        tint: workspace.tint?.color.rawValue,
                                        tintOn: workspace.tint?.parts.map(\.rawValue), root: workspace.isRoot ? true : nil, sessions: sessions)
        }
        return ControlTree(workspaces: nodes, idleMs: idleMs(), autoFollowMs: autoFollowMs,
                           attentionIncludesActive: attentionIncludesActive,
                           attentionNavigationAcrossWindows: attentionNavigationAcrossWindows,
                           sidebarVisible: sidebarVisible, sidebarMode: sidebarMode.rawValue,
                           sidebarFlaggedLayout: flaggedLayout?.rawValue, flaggedOrder: flaggedOrderReadback,
                           sidebarWidth: sidebarWidth,
                           workspaceFilter: focusEnabled,
                           quickVisible: quickVisible(), zoomedSurface: zoomedSurface(),
                           dashboardMembers: dashboardMembers(),
                           dashboardHighlighted: dashboardHighlighted(),
                           dashboardFontSize: dashboardFontSize(),
                           dashboardFontMode: dashboardFontMode(),
                           pickPending: pickPending(), askPending: askPending(), app: app, liveReset: liveReset,
                           indexUnsaved: indexUnsaved ? true : nil, snapshotUnsaved: snapshotUnsaved ? true : nil,
                           linkOpenMode: linkOpenMode?.rawValue,
                           sidebarDensity: sidebarDensity?.rawValue)
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
                              heightPercent: session.hudHeightPercent, position: spec.position.rawValue,
                              pane: session.hudTargetPane?.rawValue, hideAfter: spec.effectiveHideAfter,
                              markdown: spec.markdown, fontSize: spec.fontSize,
                              sticky: spec.sticky, frame: spec.frame)
    }
}
