import agtermCore
import Foundation

extension ControlServer {
    /// Open or close the target window's dashboard overlay — the app side of the host-free `dashboard`
    /// command (the dispatcher validated the args and built `fontMode`, but does not cap the ids). Resolves
    /// `window ?? frontmost` to an OPEN window's store. `mru` takes up to `DashboardLayout.maxCells` of that
    /// store's most-recently-used sessions (fewer if it has fewer, nothing unresolved); otherwise each id
    /// parses as a `DashboardTarget` and its head resolves within THAT store, misses reported in
    /// `result.text`. A bare id EXPANDS in order into pane cells — always `.primary`, plus `.split` when it
    /// `hasSplit` (both shells alive), so a split shows as TWO cells — while a `:left`/`:right` suffix (#331)
    /// takes that cell alone; a `:right` naming no live pane is a miss, not an error. Cells dedup by
    /// session+pane, NOT by session, so `A:left A:right` is two cells and `A A:left` is still two. The
    /// `maxCells` (9) cap counts PANES, applied here after expansion, its drops reported alongside
    /// `unresolved` (joined with "; "). Emptiness is judged on the expanded CELLS, since a resolved id can
    /// now contribute none.
    /// Each cell reparents its OWN pane surface (`\.surface` / `\.splitSurface`) app-side in
    /// `WindowContentView`. Opening closes the window's terminal zoom (mutually exclusive); `--close` calls
    /// `close()`. The registry returns nil until `WindowContentView` registers the controller (or while the
    /// window tears down), reported as the window not being open.
    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse {
        resolver.resolvePlacementStore(window) { store in
            guard let windowID = library.windowID(for: store),
                  let controller = DashboardControllerRegistry.shared.controller(for: windowID) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            if close {
                controller.close()
                return ControlResponse(ok: true)
            }
            if let error = PickRegistry.shared.controller(for: windowID)?.pendingModalError {
                return ControlResponse(ok: false, error: error)
            }
            var resolvedTargets: [ResolvedDashboardTarget] = []
            var unresolved: [String] = []
            if mru {
                let recent = store.recentSessions(limit: DashboardLayout.maxCells)
                guard !recent.isEmpty else {
                    return ControlResponse(ok: false, error: "no recent sessions")
                }
                resolvedTargets = recent.map { ResolvedDashboardTarget(session: $0, pane: nil) }
            } else {
                let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
                for target in targets {
                    guard let parsed = DashboardTarget(rawValue: target),
                          case .resolved(let id) = ControlResolve.resolve(parsed.head, candidates: candidates,
                                                                          active: store.selectedSessionID),
                          let session = store.session(withID: id) else {
                        unresolved.append(target)
                        continue
                    }
                    // a `:right` ref to a session with no split is a MISS, not a malformed command: the
                    // dispatcher already passed the grammar. `hasSplit` is the same test
                    // `dashboardValidMembers` reconciles against, so this never admits a cell reconcile
                    // would immediately prune.
                    guard parsed.pane != .split || session.hasSplit else {
                        unresolved.append(target)
                        continue
                    }
                    resolvedTargets.append(ResolvedDashboardTarget(session: id, pane: parsed.pane))
                }
            }
            // the shared host-free helper: ONE expansion+cap implementation with AppActions.toggleDashboard.
            // it also dedups, so a bare id beside a pane ref for the same session cannot double-host a surface.
            let (members, droppedPanes) = store.dashboardMembers(for: resolvedTargets,
                                                                 limit: DashboardLayout.maxCells)
            // guard the EXPANSION, not the resolved targets: with pane refs they are no longer equivalent.
            // `dashboard <id>:right` on a session with no split resolves the id but expands to nothing, and
            // opening with an empty member set would clear the window's zoom and silently close a live
            // dashboard while reporting ok (`DashboardController.isOpen` is `!members.isEmpty`).
            guard !members.isEmpty else {
                return ControlResponse(ok: false, error: "no dashboard sessions resolved")
            }
            TerminalZoomRegistry.shared.controller(for: windowID)?.clear()
            controller.open(members: members, fontMode: fontMode)
            // set the applied size SYNCHRONOUSLY so the `dashboardFontSize` read-back is authoritative at
            // command return: the SwiftUI onChange applying the surface overrides runs a runloop turn later,
            // and open() never resets appliedFontSize, so an untouched re-open would leak the prior
            // fixed/auto size. idempotent with the wiring — both go through DashboardFontMode.appliedFontSize.
            let base = settingsModel.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
            controller.setAppliedFontSize(fontMode.appliedFontSize(memberCount: members.count, base: base))
            var notes: [String] = []
            if !unresolved.isEmpty { notes.append("unresolved: \(unresolved.joined(separator: ", "))") }
            if droppedPanes > 0 {
                notes.append("dropped \(droppedPanes) pane(s) beyond the \(DashboardLayout.maxCells)-cell limit")
            }
            guard !notes.isEmpty else { return ControlResponse(ok: true) }
            return ControlResponse(ok: true, result: ControlResult(text: notes.joined(separator: "; ")))
        }
    }
}
