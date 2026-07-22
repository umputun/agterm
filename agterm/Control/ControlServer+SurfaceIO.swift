import Foundation
import agtermCore

/// `ControlServer` surface-I/O action arms — font size, selection copy, background watermark, buffer read,
/// in-terminal search, and text injection. These reach into the live `GhosttySurfaceView`, so they own the
/// surface-touching half of the dispatch. Split out of `ControlServer.swift` for the swiftlint size limit.
extension ControlServer {
    /// Resolve the target session and run a libghostty binding action on its addressable surface (targets a
    /// specific surface, unlike the menu path which only hits the focused one). Shared by the clipboard /
    /// selection arms (`session.paste`/`session.selectall`). `addressableSurface` is the main pane, falling
    /// back to a promoted split survivor whose primary shell exited (which nils `surface`) — otherwise a
    /// session the user is actively typing in would report "session not realized". A never-shown session has
    /// no surface at all → error.
    private func surfaceBindingAction(_ target: String?, window: String?, action: String) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            guard let surface = store.session(withID: id)?.addressableSurface as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            surface.performBindingAction(action)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Run a font binding action (`font.inc`/`font.dec`/`font.reset`) on a pane of the target session. A
    /// menu-driven font change rides the same CELL_SIZE → persist path as the keybind. `pane` picks the
    /// surface like `session.type`/`session.text` (`left`|`right`|`scratch`, no `other`): omitted/`left` is
    /// the main pane (`addressableSurface`, so a promoted split survivor whose primary shell exited is still
    /// reached — preserving the pre-pane behavior); `right` is the split pane (`session has no split pane`
    /// without one); `scratch` is the session's scratch terminal (`session has no scratch terminal` when none
    /// has been opened), whose surface is kept alive so its font is settable even while hidden. An unknown
    /// value is an `invalid pane` error — validated here (mirroring the CLI `validate()`) so a raw socket
    /// client can't bypass it. A resolved pane whose libghostty surface isn't realized yet returns `session
    /// not realized` (the `performBindingAction` Bool), so a split/scratch font request in the layout beat
    /// after the pane is shown never silently no-ops. Only the main pane's size persists: the split/scratch
    /// surfaces' `onFontSizeChange` is deliberately unwired, so their cmd +/- changes aren't saved (matching
    /// a GUI font change on them).
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
            // a false return = the view exists but its libghostty surface isn't realized yet (a split or
            // scratch pane in the layout beat right after it's shown); report that instead of a false ok,
            // matching session.type's inject() Bool contract so the action is never silently dropped.
            guard surface.performBindingAction(action) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Paste the system clipboard into the target session's surface (`session.paste`, the control analogue
    /// of ⌘V / Edit ▸ Paste). Runs `paste_from_clipboard`, so it takes the same libghostty paste path
    /// (bracketed paste, no OSC-52 prompt) the keyboard uses. Read the result back with `session.text`.
    func pasteSession(_ target: String?, window: String?) -> ControlResponse {
        surfaceBindingAction(target, window: window, action: "paste_from_clipboard")
    }

    /// Select the target session's entire terminal buffer (`session.selectall`, the control analogue of
    /// ⌘A / Edit ▸ Select All). Runs `select_all`; read the resulting selection back with `session.copy`.
    func selectAllSession(_ target: String?, window: String?) -> ControlResponse {
        surfaceBindingAction(target, window: window, action: "select_all")
    }

    /// Resolve the target session and return its surface's current selection text in the response (it does
    /// NOT write the system clipboard — automation pipes the returned text into another `session.type`). A
    /// never-shown session has no surface yet → error; an empty or absent selection → "no selection".
    func copySelection(_ target: String?, window: String?) -> ControlResponse {
        return resolver.resolveSession(target, window: window) { store, id in
            // `addressableSurface`, not `surface`: it must resolve the SAME pane `session.selectall` acted on,
            // including a promoted split survivor, or the documented selectall -> copy read-back breaks.
            guard let surface = store.session(withID: id)?.addressableSurface as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            guard let text = surface.readSelection() else {
                return ControlResponse(ok: false, error: "no selection")
            }
            return ControlResponse(ok: true, result: ControlResult(text: text))
        }
    }

    /// Set or clear a session's background watermark (`session.background`, mode `image|text|clear`):
    /// validate the inputs (shared `WatermarkConfig` enum checks; image format + existence), build the
    /// `BackgroundWatermark` spec (nil for `clear`), persist it on the session (`AppStore`, so it rides
    /// `SessionSnapshot`), then apply it to the session's realized surface(s). A never-shown session keeps
    /// the spec and applies it itself when its surface is created. Returns the session id.
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
            // re-applying an unchanged spec (a scripted set-loop) would leak owned configs. The store no-ops
            // its own write the same way.
            guard store.setBackgroundWatermark(watermark, forSession: id) else {
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            // clearing a `.text` watermark drops its rendered PNG so the state dir doesn't accumulate.
            if watermark == nil { WatermarkStorage.removeRenderedText(sessionID: id) }
            applyWatermark(to: session)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Apply a session's current watermark spec to its realized main + split + scratch surfaces. A never-realized
    /// surface (nil) is skipped — it applies the spec itself on creation (`GhosttySurfaceView.createSurface`).
    private func applyWatermark(to session: Session) {
        for surface in [session.surface, session.splitSurface, session.scratchSurface] {
            (surface as? GhosttySurfaceView)?.applyWatermarkFromSession()
        }
    }

    /// Returns a pane's terminal buffer as plain text: the visible screen by default, the full screen plus
    /// scrollback with `all`, or the last `lines` lines (reads the screen, then trims). `pane` picks the
    /// surface (`left` main, `right` split, `scratch` the session's scratch terminal — readable even while
    /// hidden, since its surface is kept alive — or the on-screen pane when omitted); `right` errors when
    /// the session has no split, `scratch` errors `session has no scratch terminal` when none has been
    /// opened. `all` and `lines` are mutually exclusive and `lines` must be > 0 — validated
    /// here too, not only in the CLI `validate()`, so a raw socket client can't bypass it (an unchecked
    /// `lines <= 0` would silently fall through to the full buffer). A genuinely blank screen reads ok with
    /// an empty string; a failed surface read is an error, not a silent empty.
    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse {
        let pane = options.pane, all = options.all, lines = options.lines
        if all, lines != nil {
            return ControlResponse(ok: false, error: "use either --all or --lines, not both")
        }
        if let lines, lines <= 0 {
            return ControlResponse(ok: false, error: "--lines must be greater than 0")
        }
        return resolver.resolveSession(target, window: window) { store, id in
            // resolveSession already resolved `id` from this store, so `session(withID:)` is non-nil.
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            let chosen: (any TerminalSurface)?
            switch pane {
            case nil:
                // omitted = the surface ON SCREEN (scratch-aware), the SAME `Session.onScreenSurface`
                // resolution `session.search` uses, so a no-`--pane` read returns what's visible, not a
                // pane hidden under the scratch.
                chosen = session.onScreenSurface
            case "left": chosen = session.surface
            case "right":
                guard let split = session.splitSurface else {
                    return ControlResponse(ok: false, error: "session has no split pane")
                }
                chosen = split
            case "scratch":
                // the scratch terminal's surface is kept alive while hidden, so this reads it whether or not
                // it's on screen (unlike the no-`--pane` on-screen resolution above).
                guard let scratch = session.scratchSurface else {
                    return ControlResponse(ok: false, error: "session has no scratch terminal")
                }
                chosen = scratch
            // an unknown pane value errors here; `session.text` accepts left|right|scratch, with no `other`
            // toggle like `session.focus`.
            case .some(let value): return ControlResponse(ok: false, error: "invalid pane: \(value)")
            }
            guard let surface = chosen as? GhosttySurfaceView else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            guard let text = surface.readScreenText(all: all, lines: lines) else {
                return ControlResponse(ok: false, error: "failed to read surface buffer")
            }
            return ControlResponse(ok: true, result: ControlResult(text: text))
        }
    }

    /// Drive in-terminal search on the session `id`, mirroring the GUI bar and the
    /// `session.type`/floating-overlay arms. On the `close` path it drives the session's pinned
    /// `searchSurface` WITHOUT selecting (so closing a background session's bar never yanks the user's
    /// visible selection — `endSearch()` is a side-effect-free exit, like `session.copy`). For
    /// open/needle/navigate it SELECTS the target so the bar + highlights are visible and the surface
    /// mounts, opens search on the focused pane if not already active (`startSearch`, whose START callback
    /// pins it as `searchSurface`; bounded realize-poll if a never-shown session), then sets the needle if
    /// `text` is present (`sendSearchQuery`) and steps the selection if `to == next|prev` (`navigateSearch`)
    /// — both on the PINNED owner, so a split focus move after open can't retarget them.
    /// `to` must be one of next/prev/close (else an `invalid` error). The match count lands asynchronously
    /// via libghostty's SEARCH_TOTAL callback; `searchTotal`/`searchSelected` are cleared before the query so
    /// the bounded main-actor poll waits for the FRESH count (not a stale prior needle's), then `count` + the
    /// "N of M" display string are returned in `text`.
    func searchSession(_ target: String?, window: String?, text: String?, to: String?) async -> ControlResponse {
        // Resolve first (cross-window when no `window`), then select + realize the surface; the realize
        // path is async (bounded poll), so this can't go through the synchronous `resolveSession`
        // helper. Error strings stay in sync with `resolve(...)`, and target lookup preserves the
        // pre-dispatcher error order by winning over `to` validation.
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

        // close exits search without selecting: a background session's surface is already realized while
        // hidden, and end_search has no visible side effect, so don't disturb the user's active session.
        // drive the PINNED `searchSurface` (the pane that opened search), not a re-resolved `activeSurface`
        // — if split focus moved after open, `activeSurface` is the wrong pane and would strand the owner.
        // with no open search there's no owner, so close is a clean no-op.
        if to == "close" {
            (session.searchSurface as? GhosttySurfaceView)?.endSearch()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        if let windowID = library.windowID(forSession: id),
           TerminalZoomRegistry.shared.controller(for: windowID)?.target != nil {
            return ControlResponse(ok: false, error: "terminal zoom active")
        }

        // open/needle/navigate need the bar + highlights visible, so select the target (also realizes a
        // never-shown surface). the OPEN uses the search target — a covering scratch (scratchActive, no
        // overlay) wins, mirroring AppActions.searchTarget(), else the focused pane; the factory pins it as
        // `searchSurface`, and once open needle/navigate target the pinned owner so they can't drift.
        store.selectSession(id)
        // a covering scratch is searchable and sits above the pane, so drive it, not the hidden pane beneath
        // (`onScreenSurface` is the shared pane-vs-scratch resolution, also used by `session.text`).
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
            // on a needle CHANGE, an OLDER query's SEARCH_TOTAL callback can still be queued on the main
            // loop (callbacks hop via DispatchQueue.main.async). drain one run-loop turn FIRST so any such
            // stale callback is delivered, THEN clear — so the settle-poll below waits for THIS needle's
            // callback (sent AFTER the clear) rather than reading a stale count. re-sending the SAME needle
            // must NOT drain/clear: libghostty does not re-emit SEARCH_TOTAL for an unchanged query, so
            // clearing would leave the count nil (the retry idiom re-sends the same needle while the
            // scrollback renders). residual race: a stale callback delivered more than one run-loop turn
            // late (blocked behind heavy render work) could still land after the clear; a per-query epoch
            // through libghostty would close it fully but is out of scope here.
            if needleChanged {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 30_000_000)
                session.searchTotal = nil
                session.searchSelected = nil
            }
            session.searchNeedle = text
            surface.sendSearchQuery(text)
            // an explicitly-empty needle clears the query: libghostty tears the search thread down and
            // emits no fresh SEARCH_TOTAL (its quit event resets the count), so reset the count/selected
            // here and skip the settle-poll below — there is nothing to wait for, and polling would just
            // burn the full timeout reading a count that never lands.
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
        // an empty display string (the bar opened with no query yet) maps to a nil `text` so the CLI
        // prints `ok` rather than a blank line; the count is nil until a query runs.
        let display = session.searchDisplayText
        return ControlResponse(ok: true, result: ControlResult(text: display.isEmpty ? nil : display,
                                                               count: session.searchTotal))
    }

    /// Inject `text` into the session `id`'s surface. A session's surface is created lazily (deferred until
    /// it has a non-zero backing size — a never-shown session has `surface == nil`). `inject(text:)` sends
    /// the text as `ghostty_surface_key` keystrokes (NOT `ghostty_surface_text` — see its doc for why),
    /// which write to the child pty; the kernel buffers the pty, so text is never lost even before the
    /// first prompt.
    /// `pane` picks the pane like `session.text` (`left`|`right`|`scratch`, no `other`): omitted/`left` is
    /// the main pane (omitted keeps the pre-pane behavior — always the main pane, NOT the focused one, so
    /// existing automation is unaffected); `right` is the split pane, `session has no split pane` without
    /// one; `scratch` is the session's scratch terminal, typable even while hidden (its surface is kept
    /// alive), `session has no scratch terminal` when none has been opened. The realize/select path below
    /// applies to the main pane only — a split pane is never created by selecting, so `right`/`scratch`
    /// inject into the existing surface or error.
    /// - surface already realized → inject immediately, ok.
    /// - never realized, `select:true` → select it, then poll for the surface (bounded: 12 × 0.03 s, the
    ///   `focusSplitPane` idiom) and inject on the first realized attempt; never realized → error (never a
    ///   false ok).
    /// - never realized, no select → an immediate "use select" error.
    func injectText(_ text: String, into id: UUID, store: AppStore, select: Bool, pane: String?) async -> ControlResponse {
        switch pane {
        case nil, "left":
            break
        case "right":
            guard let split = store.session(withID: id)?.splitSurface else {
                return ControlResponse(ok: false, error: "session has no split pane")
            }
            // inject returns false when the view exists but its libghostty surface isn't realized yet
            // (there is no realize/select path for the split pane) — report that instead of a false ok.
            guard let surface = split as? GhosttySurfaceView, surface.inject(text: text) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        case "scratch":
            // the scratch terminal's surface is kept alive while hidden, so this types into it whether or
            // not it's on screen; `session has no scratch terminal` when none has been opened. As with
            // `right`, a false `inject` (surface not yet realized in the ms after `session.scratch on`,
            // before layout) reports `session not realized` rather than silently dropping the keystrokes.
            guard let scratch = store.session(withID: id)?.scratchSurface else {
                return ControlResponse(ok: false, error: "session has no scratch terminal")
            }
            guard let surface = scratch as? GhosttySurfaceView, surface.inject(text: text) else {
                return ControlResponse(ok: false, error: "session not realized")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        // an unknown pane value errors here; `session.type` accepts left|right|scratch, with no `other`
        // toggle like `session.focus` (mirroring `session.text`).
        case .some(let value):
            return ControlResponse(ok: false, error: "invalid pane: \(value)")
        }
        // main pane: inject if realized; a false return (the view exists but its libghostty surface isn't
        // up yet) falls through to the select/poll path rather than returning a silent-drop false ok.
        if let surface = store.session(withID: id)?.surface as? GhosttySurfaceView, surface.inject(text: text) {
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        guard select else {
            return ControlResponse(ok: false, error: "session not realized; use select")
        }
        store.selectSession(id)
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            // poll for the surface AND its realization (a false inject keeps polling), so a just-selected
            // never-shown session isn't reported ok before its libghostty surface is actually up.
            if let surface = store.session(withID: id)?.surface as? GhosttySurfaceView, surface.inject(text: text) {
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        }
        return ControlResponse(ok: false, error: "session not realized")
    }
}
