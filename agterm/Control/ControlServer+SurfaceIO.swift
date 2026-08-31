import Foundation
import agtermCore

/// `ControlServer` arms that reach into a live `GhosttySurfaceView` — font size, selection copy, background
/// watermark, buffer read, in-terminal search, text injection. Split out for the swiftlint size limit.
extension ControlServer {
    /// Runs a libghostty binding action on the target's addressable surface — a SPECIFIC one, unlike the menu
    /// path's focused pane. Shared by `session.paste`/`session.selectall`; `Session.addressableSurface` owns
    /// which pane that resolves to. An empty slot and a parked view whose surface never came up are one state
    /// to a caller: "session not realized".
    private func surfaceBindingAction(_ target: String?, window: String?, action: String) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let surface = store.session(withID: id)?.addressableSurface as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            // the cast alone only proves the SLOT is filled; a false return is the view without a surface.
            guard surface.performBindingAction(action) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Runs a font binding action (`font.inc`/`font.dec`/`font.reset`) on a pane of the target session; a
    /// menu-driven change rides the same CELL_SIZE → persist path as the keybind. `pane` follows
    /// `session.type`/`session.text` (`left`|`right`|`scratch`, no `other`): omitted/`left` is the main pane
    /// via `addressableSurface` (the pre-pane behavior, still reaching a promoted split survivor); `scratch`
    /// is settable while hidden, its surface kept alive. An unknown value is rejected here as well as in the
    /// CLI `validate()`, so a raw socket client can't bypass it, and a resolved-but-unrealized pane returns
    /// `session not realized` rather than silently no-opping in the layout beat after the pane is shown.
    /// Only the surface currently in the main role persists its size; split-role and scratch changes stay live-only.
    func font(_ target: String?, window: String?, pane: String?, action: String) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            // resolveSession already resolved `id` from this store, so `session(withID:)` is non-nil.
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            let chosen: (any TerminalSurface)?
            switch pane {
            case nil, "left":
                chosen = session.addressableSurface
            case "right":
                guard let split = session.splitSurface else {
                    return ControlResponse(ok: false, error: "session has no split pane")
                }
                chosen = split
            case "scratch":
                guard let scratch = session.scratchSurface else {
                    return ControlResponse(ok: false, error: "session has no scratch terminal")
                }
                chosen = scratch
            case .some(let value):
                return ControlResponse(ok: false, error: "invalid pane: \(value)")
            }
            guard let surface = chosen as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            // a false return = surface not realized yet; report it, not a false ok (session.type's contract).
            guard surface.performBindingAction(action) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// The ⌘V / Edit ▸ Paste analogue (`session.paste`): the same libghostty `paste_from_clipboard` the
    /// keyboard takes, so bracketed paste applies and no OSC-52 prompt appears. Read back with `session.text`.
    func pasteSession(_ target: String?, window: String?) -> ControlResponse {
        surfaceBindingAction(target, window: window, action: "paste_from_clipboard")
    }

    /// Selects the target session's entire terminal buffer (`session.selectall`, the ⌘A / Edit ▸ Select All
    /// analogue); read the resulting selection back with `session.copy`.
    func selectAllSession(_ target: String?, window: String?) -> ControlResponse {
        surfaceBindingAction(target, window: window, action: "select_all")
    }

    /// Returns the surface's current selection text in the response, NOT to the system clipboard (automation
    /// pipes it into another `session.type`). No surface → error; empty or absent selection → "no selection".
    func copySelection(_ target: String?, window: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            // `addressableSurface`, not `surface`: must resolve the SAME pane `session.selectall` acted on,
            // promoted split survivor included, or the documented selectall -> copy read-back breaks.
            guard let surface = store.session(withID: id)?.addressableSurface as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            // an unrealized pane has no selection to report EITHER way, and `readSelection` cannot tell the
            // two apart — so answer it as `session.selectall` does rather than blaming an empty selection.
            guard surface.isRealized else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            guard let text = surface.readSelection() else {
                return ControlResponse(ok: false, error: "no selection")
            }
            return ControlResponse(ok: true, result: ControlResult(text: text))
        }
    }

    /// The outcome of resolving an overlay read's surface: the view, or the rejection the arm returns as-is.
    private enum OverlayReadSurface {
        case surface(GhosttySurfaceView)
        case rejected(ControlResponse)
    }

    /// The surface `session.overlay.copy`/`.text` address: the pane's own overlay with `pane`, else the
    /// session-wide slot. Shared by both, so `no overlay` and `overlay not realized` cannot come to mean
    /// different things on one command than the other. A filled slot with an unrealized surface is the ms
    /// after `overlay.open`, and it names the OVERLAY rather than borrowing `session not realized`: the
    /// session is fine, it is the cover that is not up. A HUD is refused ahead of everything, `overlayActive`
    /// alone being unable to tell the app's own painter from a caller's program.
    private func overlayReadSurface(_ session: Session, pane: OverlayPane?) -> OverlayReadSurface {
        let occupied: Bool
        let surface: (any TerminalSurface)?
        if let pane {
            occupied = session.paneOverlay(pane) != nil
            surface = session.paneOverlaySurface(pane)
        } else {
            if session.hudActive {
                return .rejected(ControlResponse(ok: false, error: OverlayHudError.noRead))
            }
            occupied = session.overlayActive
            surface = session.overlaySurface
        }
        guard occupied else { return .rejected(ControlResponse(ok: false, error: "no overlay")) }
        guard let view = surface as? GhosttySurfaceView, view.isRealized else {
            return .rejected(ControlResponse(ok: false, error: "overlay not realized"))
        }
        return .surface(view)
    }

    /// Returns the OVERLAY's current selection (`session.overlay.copy`), which `session.copy` cannot reach:
    /// that one addresses `addressableSurface`, the pane the overlay covers, so a selection the user made in
    /// the overlay reads as `no selection` there. Returns the text rather than writing the clipboard, like
    /// its session-level twin. The realization gate above runs first, so nil here is genuinely no selection.
    func copySessionOverlaySelection(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            switch self.overlayReadSurface(session, pane: pane) {
            case .rejected(let response): return response
            case .surface(let surface):
                guard let text = surface.readSelection() else {
                    return ControlResponse(ok: false, error: "no selection")
                }
                return ControlResponse(ok: true, result: ControlResult(text: text))
            }
        }
    }

    /// Returns the OVERLAY's terminal buffer (`session.overlay.text`), `session.text`'s counterpart for the
    /// covering surface — `--pane right` reads the shell underneath, never the program drawn over it. `all`
    /// and `lines` mean what they do on `session.text`, the dispatcher having validated them the same way.
    /// What comes back is a TUI's DRAWN screen, wrapped as rendered, not the output it would have printed.
    func readSessionOverlayText(_ target: String?, window: String?,
                                options: ControlSessionOverlayTextOptions) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            switch self.overlayReadSurface(session, pane: options.pane) {
            case .rejected(let response): return response
            case .surface(let surface):
                guard let text = surface.readScreenText(all: options.all, lines: options.lines) else {
                    return ControlResponse(ok: false, error: "failed to read surface buffer")
                }
                return ControlResponse(ok: true, result: ControlResult(text: text))
            }
        }
    }

    /// Sets or clears a session's background watermark (mode `image|text|clear`): validate the inputs (shared
    /// `WatermarkConfig` enum checks; image format + existence), persist the spec on the session so it rides
    /// `SessionSnapshot`, then apply it to the realized surface(s). A never-shown session keeps the spec and
    /// applies it itself on surface creation. Returns the session id.
    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse {
        let watermark = options.watermark
        if let watermark, watermark.kind == .image {
            guard let path = watermark.imagePath, !path.isEmpty else {
                return ControlResponse(ok: false, error: "session.background image requires a path")
            }
            guard WatermarkRenderer.isSupportedImage(path) else {
                return ControlResponse(ok: false, error: "unsupported image (PNG or JPEG only): \(path)")
            }
            guard FileManager.default.fileExists(atPath: path) else {
                return ControlResponse(ok: false, error: "no such image file: \(path)")
            }
        }
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            // gate on a real change: applyWatermark RETAINS a per-surface config freed only on teardown, so
            // re-applying an unchanged spec (a scripted set-loop) leaks owned configs. the store no-ops too.
            guard store.setBackgroundWatermark(watermark, forSession: id) else {
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            // clearing a `.text` watermark drops its rendered PNG so the state dir doesn't accumulate.
            if watermark == nil { WatermarkStorage.removeRenderedText(sessionID: id) }
            applyWatermark(to: session)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Apply a session's watermark spec to its realized main + split + scratch surfaces. A never-realized one
    /// (nil) is skipped — it applies the spec itself on creation (`GhosttySurfaceView.createSurface`).
    private func applyWatermark(to session: Session) {
        for surface in [session.surface, session.splitSurface, session.scratchSurface] {
            (surface as? GhosttySurfaceView)?.applyWatermarkFromSession()
        }
    }

    /// Returns a pane's terminal buffer as plain text: the visible screen by default, screen + scrollback
    /// with `all`, or the last `lines` lines (reads the screen, then trims). `paneID` resolves the surface's
    /// live slot before `pane`, which picks left/right/scratch (the scratch readable while hidden, its surface
    /// kept alive), or the on-screen pane when omitted. `all` and `lines` are mutually exclusive and `lines`
    /// must be > 0, rejected here as well as in the CLI so a raw socket client can't bypass it.
    /// A genuinely blank screen reads ok with an empty string; a failed read is an error, not a silent empty.
    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse {
        let all = options.all, lines = options.lines
        if all, lines != nil {
            return ControlResponse(ok: false, error: "use either --all or --lines, not both")
        }
        if let lines, lines <= 0 {
            return ControlResponse(ok: false, error: "--lines must be greater than 0")
        }
        return resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            let pane = Self.resolvedSessionTextPane(in: session, pane: options.pane, paneID: options.paneID)
            let chosen: (any TerminalSurface)?
            switch pane {
            case nil:
                // omitted = the ON-SCREEN surface (as `session.search` resolves it), never a pane hidden
                // under the scratch.
                chosen = session.onScreenSurface
            case "left": chosen = session.surface
            case "right":
                guard let split = session.splitSurface else {
                    return ControlResponse(ok: false, error: "session has no split pane")
                }
                chosen = split
            case "scratch":
                guard let scratch = session.scratchSurface else {
                    return ControlResponse(ok: false, error: "session has no scratch terminal")
                }
                chosen = scratch
            // `session.text` accepts left|right|scratch, with no `other` toggle like `session.focus`.
            case .some(let value): return ControlResponse(ok: false, error: "invalid pane: \(value)")
            }
            guard let surface = chosen as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            // a view parked in the slot whose libghostty surface never came up is UNREALIZED, not a failed
            // read — the deck installs the view before `createSurface`, and creation is refused outright
            // while the display sleeps (#416). Without this the same state answered `failed to read surface
            // buffer` here and `session not realized` from every other command, naming a cause that did not
            // happen: nothing failed to read, there was nothing to read from.
            guard surface.isRealized else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            guard let text = surface.readScreenText(all: all, lines: lines) else {
                return ControlResponse(ok: false, error: "failed to read surface buffer")
            }
            return ControlResponse(ok: true, result: ControlResult(text: text))
        }
    }

    /// A stable surface token wins over its baked role by resolving against the session's current slots.
    /// Empty or unknown tokens preserve the explicit pane fallback.
    static func resolvedSessionTextPane(in session: Session, pane: String?, paneID: String?) -> String? {
        paneID.flatMap { session.paneRole(forToken: $0)?.rawValue } ?? pane
    }

    /// Returns the addressed surface's zero-based cursor column. Takes `surface.zoom`'s target vocabulary —
    /// `surface:<session-id>:<kind>` ids from `tree`, `quick`, or `active` for the frontmost (or `--window`)
    /// window's active surface — so both `surface.*` commands address the same set. Unlike zoom it changes
    /// nothing, so it neither selects nor realizes the target: an unrealized surface is reported, not waited
    /// for. `GhosttySurfaceView.readCursorColumn` owns how the column is derived and when it declines.
    func readSurfaceCursor(_ target: String?, window: String?) -> ControlResponse {
        let rawTarget = trimmed(target) ?? "active"
        if rawTarget == "quick" {
            // `hide()` deliberately keeps the panel's surface alive, so visibility is the gate, not the
            // surface existing — otherwise a panel shown once stays readable forever. Same test `setZoom` makes.
            guard QuickTerminalController.shared.isVisible,
                  let surface = QuickTerminalController.shared.currentSurface() else {
                return ControlResponse(ok: false, error: "surface not available: quick")
            }
            return cursorResponse(surface, controlID: "quick")
        }
        let resolved: (store: AppStore, target: TerminalZoomTarget)
        if rawTarget == "active" {
            switch resolveOpenWindow(window) {
            case .failure(let response):
                return response
            case .success(let (windowID, store)):
                // a live zoom IS the active surface, and `surface.zoom active` resolves it the same way: the
                // controller's target wins over the store's focused pane, which zooming a NONFOCUSED pane
                // never moves.
                guard let zoomTarget = TerminalZoomRegistry.shared.controller(for: windowID)?.target
                        ?? TerminalZoomController.resolveTarget(store: store) else {
                    return ControlResponse(ok: false, error: "no active surface")
                }
                resolved = (store, zoomTarget)
            }
        } else {
            guard let surfaceID = TerminalSurfaceID(rawValue: rawTarget) else {
                return ControlResponse(ok: false, error: "invalid surface: \(rawTarget)")
            }
            switch resolveSurfaceOwner(surfaceID, window: window) {
            case .failure(let response):
                return response
            case .success(let (_, store)):
                resolved = (store, .session(surfaceID.sessionID, surfaceID.surface))
            }
        }
        // the same validity gate `surface.zoom` applies, so an explicit id cannot reach an occupant the tree
        // refuses to address: a HUD fills `overlaySurface` while `.overlay` reads unavailable, and without
        // this a guessed `surface:<id>:overlay` would report the app's own message painter's cursor.
        guard case let .session(sessionID, kind) = resolved.target,
              let session = resolved.store.session(withID: sessionID),
              TerminalZoomController.isTargetValid(resolved.target, in: resolved.store) else {
            return ControlResponse(ok: false, error: "surface not available: \(resolved.target.controlID)")
        }
        return cursorResponse(kind.surface(in: session) as? GhosttySurfaceView, controlID: resolved.target.controlID)
    }

    private func cursorResponse(_ surface: GhosttySurfaceView?, controlID: String) -> ControlResponse {
        guard let surface else {
            return ControlResponse(ok: false, error: "surface not available: \(controlID)")
        }
        // an occupied slot proves nothing about a running terminal — the deck parks the view before
        // `createSurface`, which the display being asleep refuses outright (#416).
        guard surface.isRealized else {
            return ControlResponse(ok: false, error: "surface not realized")
        }
        guard let column = surface.readCursorColumn() else {
            return ControlResponse(ok: false, error: "failed to read cursor position")
        }
        return ControlResponse(ok: true, result: ControlResult(id: controlID, cursor: ControlCursor(column: column)))
    }

    /// Drives in-terminal search on session `id`, mirroring the GUI bar. `close` exits without selecting;
    /// open/needle/navigate select the target, open search on the focused pane if not already active, then
    /// set the needle and step on `to == next|prev` — all on the PINNED `searchSurface`, so a split focus
    /// move after open can't retarget them. `to` must be next/prev/close. The count lands asynchronously via
    /// libghostty's SEARCH_TOTAL callback, so a bounded main-actor poll waits for it before returning
    /// `count` + the "N of M" string in `text`.
    func searchSession(_ target: String?, window: String?, text: String?, to: String?) async -> ControlResponse {
        // resolve first (cross-window when no `window`), then select + realize: the realize path is async
        // (bounded poll), so the synchronous `resolveSession` helper can't serve. Error strings stay in sync
        // with `resolve(...)`; target lookup must win over `to` validation.
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let response):
            return response
        case .success(let (store, id)):
            return await searchSession(id, store: store, text: text, to: to)
        }
    }

    func searchSession(_ id: UUID, store: AppStore, text: String?, to: String?) async -> ControlResponse {
        // validate `to` up front so a bad mode errors before touching the surface.
        if let to, !["next", "prev", "close"].contains(to) {
            return ControlResponse(ok: false, error: "session.search --to must be next|prev|close")
        }
        guard let session = store.session(withID: id) else {
            return ControlResponse(ok: false, error: "no such session")
        }

        // close exits without selecting: a hidden session's surface is already realized and end_search has no
        // visible side effect, so don't disturb the active session. Drive the PINNED `searchSurface`, not a
        // re-resolved `activeSurface` — after a split focus move that is the wrong pane and strands the
        // owner; with no open search there is no owner, so close no-ops.
        if to == "close" {
            (session.searchSurface as? GhosttySurfaceView)?.endSearch()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        if let windowID = library.windowID(forSession: id) {
            if PickRegistry.shared.controller(for: windowID)?.pending != nil {
                return ControlResponse(ok: false, error: "pick pending")
            }
            if TerminalZoomRegistry.shared.controller(for: windowID)?.target != nil {
                return ControlResponse(ok: false, error: "terminal zoom active")
            }
        }

        // open/needle/navigate need the bar + highlights visible, so select the target (which also realizes
        // a never-shown surface). The OPEN uses the search target — a covering scratch wins, mirroring
        // `AppActions.searchTarget()`, else the focused pane; the factory pins it as `searchSurface`.
        store.selectSession(id)
        // `onScreenSurface` is the shared pane-vs-scratch resolution, also used by `session.text`.
        var openSurface = session.onScreenSurface as? GhosttySurfaceView
        if openSurface == nil {
            // a never-shown session realizes a beat after select — bounded poll like `injectText`.
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                if let realized = session.onScreenSurface as? GhosttySurfaceView {
                    openSurface = realized
                    break
                }
            }
        }
        guard let openSurface else {
            return ControlResponse(ok: false, error: "session not realized")
        }

        // `searchActive` here means a prior open settled (set by the async START callback); two rapid
        // scripted opens could mis-toggle, but the GUI's single-⌘F path is the common case.
        if !session.searchActive { openSurface.startSearch() }
        // all post-open drives go to the pinned owner; before the first START callback lands it is nil, so
        // fall back to the just-opened focused pane (which the factory is about to pin to the same surface).
        let surface = (session.searchSurface as? GhosttySurfaceView) ?? openSurface
        let needleChanged = text != nil && text != session.searchNeedle
        if let text {
            // on a needle CHANGE an OLDER query's SEARCH_TOTAL may still be queued on the main loop
            // (callbacks hop via DispatchQueue.main.async), so drain one run-loop turn to deliver it BEFORE
            // clearing; the settle-poll then waits for THIS needle's callback, not a stale count. The SAME
            // needle must NOT drain/clear: libghostty does not re-emit SEARCH_TOTAL for an unchanged query,
            // so clearing would leave the count nil. Residual race: a callback more than one turn late
            // (behind heavy render work) still lands after the clear; only a per-query epoch closes that.
            if needleChanged {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 30_000_000)
                session.searchTotal = nil
                session.searchSelected = nil
            }
            session.searchNeedle = text
            surface.sendSearchQuery(text)
            // an explicitly-empty needle clears the query: libghostty tears the search thread down and emits
            // no fresh SEARCH_TOTAL, so reset count/selected here and skip the settle-poll (it would burn
            // the full timeout waiting for nothing).
            if text.isEmpty {
                session.searchTotal = nil
                session.searchSelected = nil
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        }
        switch to {
        case "next": surface.navigateSearch(.next)
        case "prev": surface.navigateSearch(.previous)
        default: break
        }
        // let the SEARCH_TOTAL callback land before reporting (the overlay-result / realize poll idiom).
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if session.searchTotal != nil { break }
        }
        // an empty display string (the bar opened with no query yet) maps to nil so the CLI prints `ok`
        // rather than a blank line; the count is nil until a query runs.
        let display = session.searchDisplayText
        return ControlResponse(ok: true, result: ControlResult(text: display.isEmpty ? nil : display,
                                                               count: session.searchTotal))
    }

    /// Injects `text` into session `id`'s surface. The deck mounts every session, but realization still
    /// needs a SwiftUI pass plus an AppKit layout pass (`createSurface` defers on a zero backing size), so a
    /// session created moments ago is briefly unrealized whether or not it is selected. `inject(text:)` sends
    /// the text as `ghostty_surface_key` keystrokes (NOT `ghostty_surface_text` — see its doc for why), which
    /// write to the child pty; the kernel buffers the pty, so text is never lost even before the first prompt.
    /// `ok` therefore means the keystrokes were queued to the pty, NOT that the shell read or ran them (#350):
    /// libghostty's write mailbox blocks rather than drops, messages queued before the io thread starts are
    /// drained once the subprocess is up, and nothing flushes pending tty input. A caller that needs execution
    /// polls `session.text` for its effect; `ghostty_surface_key`'s bool reports consumption, not delivery, so
    /// it is no readiness signal either.
    /// `pane` follows `session.text` (`left`|`right`|`scratch`, no `other`): omitted/`left` is the main pane,
    /// NOT the focused one — the pre-pane behavior, so existing automation is unaffected; `scratch` is
    /// typable while hidden since its surface is kept alive. Selecting never creates a split pane, so the
    /// realize/select path below is main-pane only and `right`/`scratch` inject or error.
    /// - already realized → inject immediately, ok, and `select` does NOT move the user's selection.
    /// - unrealized → optionally select, then poll (bounded: 12 × 0.03 s, the `focusSplitPane` idiom) and
    ///   inject on the first realized attempt; still unrealized → error, never a false ok.
    ///
    /// The poll runs WITHOUT `select` too (#349): a background `session.new --no-select` replies from a
    /// synchronous store mutation, so a back-to-back `session.type` raced the mount and failed, and the
    /// documented workaround (select, then re-select) tears down the workspace focus filter, consumes the
    /// previous session's auto-reset indicator, and rewrites recency. `quick.type` polls after `quick show`
    /// for the same reason. A call that succeeds on the first probe pays no wait at all; the sleeps below are
    /// only reached once that probe has already failed.
    func injectText(_ text: String, into id: UUID, store: AppStore, select: Bool, pane: String?) async -> ControlResponse {
        switch pane {
        case nil, "left":
            break
        case "right":
            guard let split = store.session(withID: id)?.splitSurface else {
                return ControlResponse(ok: false, error: "session has no split pane")
            }
            // inject returns false when the view exists but its libghostty surface isn't realized yet (there
            // is no realize/select path for the split pane) — report that instead of a false ok.
            guard let surface = split as? GhosttySurfaceView, surface.injectAsUserInput(text: text) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        case "scratch":
            // as with `right`, a false `inject` (the ms after `session.scratch on`, before layout) reports
            // `session not realized` rather than silently dropping the keystrokes.
            guard let scratch = store.session(withID: id)?.scratchSurface else {
                return ControlResponse(ok: false, error: "session has no scratch terminal")
            }
            guard let surface = scratch as? GhosttySurfaceView, surface.injectAsUserInput(text: text) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        // `session.type` accepts left|right|scratch, with no `other` toggle (mirroring `session.text`).
        case .some(let value):
            return ControlResponse(ok: false, error: "invalid pane: \(value)")
        }
        // main pane: inject if realized; a false return (view exists, libghostty surface not up yet) falls
        // through to the poll rather than returning a silent-drop false ok. This probe precedes the select
        // below, so `--select` on a realized session leaves the user's selection alone.
        if let surface = store.session(withID: id)?.surface as? GhosttySurfaceView, surface.injectAsUserInput(text: text) {
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        if select { store.selectSession(id) }
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            // poll for the surface AND its realization (a false inject keeps polling), so a just-created or
            // just-selected session isn't reported ok before its libghostty surface is up.
            if let surface = store.session(withID: id)?.surface as? GhosttySurfaceView, surface.injectAsUserInput(text: text) {
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        }
        return ControlResponse(ok: false, error: "session not realized")
    }
}
