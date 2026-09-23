import AppKit
import CoreText
import Foundation
import os
import agtermCore

private let hudLogger = Logger(subsystem: "com.umputun.agterm", category: "ControlHud")

/// A session's live auto-hide timer and the revision that armed it. The revision is what makes a superseded
/// callback inert: an update restarts the interval without bumping `Session.overlaySlotGeneration`, which
/// would recreate the panel's surface.
struct HudAutoHide {
    let revision: Int
    /// When the panel comes down. A viewer's remaining lifetime is sampled from it, so a late subscriber
    /// gets what is left and not the configured interval again.
    let deadline: Date
    let task: Task<Void, Never>
}

/// App-side host for `session.hud.*`. Validation, error text and response shape stay in
/// `ControlDispatcher+Hud`; this layer supplies the three things agtermCore cannot resolve — the bundled
/// helper's path, the terminal font's cell size, and live geometry, plus the body file the helper reads.
extension ControlServer {
    /// Arms `spec`'s auto-hide for `session`, replacing whatever was armed before, registers the
    /// cancellation the store calls from `discardHudBody`, and publishes the panel to attached viewers with
    /// the deadline it now has. A spec with no auto-hide only cancels, and still publishes.
    ///
    /// Called after the body write succeeds, never before: a rejected open or update must leave the panel
    /// that is actually on screen with the deadline it actually has, and must not reach a viewer.
    func armHudAutoHide(_ session: Session, spec: HudSpec) {
        let id = session.id
        defer {
            library.store(forSession: id)?.publishHud(forSession: id, expiresAt: hudAutoHide[id]?.deadline,
                                                      now: hudClock())
        }
        let revision = (hudAutoHide[id]?.revision ?? 0) + 1
        hudAutoHide[id]?.task.cancel()
        hudAutoHide[id] = nil
        // clamped as well as validated: the conversion below traps on a large enough Double, and a raw-socket
        // caller reaching here past a validation that drifted must not take the app with it.
        let seconds = min(spec.effectiveHideAfter, HudSpec.maxHideAfter)
        guard seconds > 0 else { return }
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.hudAutoHide[id]?.revision == revision else { return }
            self.hudAutoHide[id] = nil
            // through the store, so the body file goes with the panel and the deck sees the slot empty.
            self.library.store(forSession: id)?.closeHud(id)
        }
        hudAutoHide[id] = HudAutoHide(revision: revision, deadline: hudClock().addingTimeInterval(seconds),
                                      task: task)
        session.onHudDiscarded = { [weak self] in
            MainActor.assumeIsolated {
                self?.hudAutoHide[id]?.task.cancel()
                self?.hudAutoHide[id] = nil
            }
        }
    }
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        openHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    func openHud(_ target: String?, window: String?, spec: HudSpec,
                 placement: ControlHudPlacement) -> ControlResponse {
        openHud(target, window: window, spec: spec, placement: placement, fallbackToSession: false)
    }

    func openCommandFailureHud(_ target: String, spec: HudSpec, pane: OverlayPane?) -> ControlResponse {
        openHud(target, window: nil, spec: spec, placement: ControlHudPlacement(pane: pane), fallbackToSession: true)
    }

    /// A pane the origin placed its panel over may not be laid out here, so this falls back to session-wide.
    func openRemoteHud(_ target: String, spec: HudSpec, placement: ControlHudPlacement) -> ControlResponse {
        openHud(target, window: nil, spec: spec, placement: placement, fallbackToSession: true)
    }

    private func openHud(_ target: String?, window: String?, spec: HudSpec,
                         placement: ControlHudPlacement, fallbackToSession: Bool) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            guard let command = Self.helperCommand() else {
                return ControlResponse(ok: false, error: "hud helper is not bundled in this build")
            }
            let paneIdentity: UUID?
            let pane: OverlayPane?
            switch self.resolvePanePlacement(placement.pane, paneID: placement.paneID, in: session,
                                            requireVisible: true, invalidPaneError: "hud pane must be left or right") {
            case .resolved(let identity, let targetPane):
                paneIdentity = identity
                pane = targetPane
            case .rejected(let response):
                guard fallbackToSession else { return response }
                hudLogger.notice("failure panel for \"\(spec.message, privacy: .public)\" falling back to session-wide placement: \(response.error ?? "unknown placement error", privacy: .public)")
                paneIdentity = nil
                pane = nil
            }
            let file = Self.bodyFile(for: id)
            // resolved before measuring and stored only by the open: a replaced HUD's teardown clears the
            // session's stored size, so reading it here would measure the predecessor's font.
            let fontSize = spec.fontSize ?? session.fontSize ?? GhosttyApp.shared.baseFontSize
            // measured ONCE and threaded through: the sizing and the header describe the same panel, and
            // both a font lookup and a pane-geometry union would otherwise run twice per command.
            let metrics = self.paneMetrics(for: session, pane: pane, fontSize: fontSize)
            // open FIRST, write second: replacing a live HUD tears its surface down, and that teardown
            // deletes the body file at this same per-session path — writing first would lose it. The
            // header's grid also comes from the size the store RESOLVED, which only exists after this call.
            guard store.openHud(id, command: command, spec: spec, file: file,
                                size: HudLayout.panelSize(for: spec, pane: metrics),
                                paneIdentity: paneIdentity, fontSize: fontSize) else {
                return ControlResponse(ok: false, error: "overlay already open")
            }
            // the rolled-back HUD never realized a surface, and a replaced predecessor's file sits at this
            // same path: `Session.discardHudBody`, which `closeHud` routes through, deletes both.
            guard self.writeHudBody(session, pane: metrics) else {
                store.closeHud(id)
                return ControlResponse(ok: false, error: OverlayHudError.writeFailed)
            }
            self.watchHudGeometry(session)
            self.armHudAutoHide(session, spec: spec)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Rewrites the live HUD's body and re-sizes the panel in place, repainting with no re-spawn per
    /// `HudLayout.renderedBody`. A failed write rolls the store back, as `openHud` does with `closeHud`:
    /// the panel still paints the old message, and `tree` must not claim the new one.
    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        updateHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    func updateHud(_ target: String?, window: String?, spec: HudSpec,
                   placement: ControlHudPlacement) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            // `hudActive` is the occupancy question, asked once and separately from the mutation below, so
            // a store that refused for another reason cannot come back as `noHud`.
            guard let session = store.session(withID: id), session.hudActive,
                  let previous = session.hudSpec, let previousSize = session.overlaySizePercent,
                  let previousHeight = session.hudHeightPercent else {
                return ControlResponse(ok: false, error: OverlayHudError.noHud)
            }
            let paneIdentity: UUID?
            let pane: OverlayPane?
            switch self.resolvePanePlacement(placement.pane, paneID: placement.paneID, in: session,
                                            requireVisible: false, invalidPaneError: "hud pane must be left or right") {
            case .resolved(let identity, let targetPane):
                paneIdentity = identity
                pane = targetPane
            case .rejected(let response): return response
            }
            let previousPaneIdentity = session.hudPaneIdentity
            let metrics = self.paneMetrics(for: session, pane: pane, fontSize: self.liveHudFontSize(session))
            store.updateHud(id, spec: spec, size: HudLayout.panelSize(for: spec, pane: metrics),
                            paneIdentity: paneIdentity)
            guard self.writeHudBody(session, pane: metrics) else {
                // the panel still paints the old message, so it keeps the deadline that came with it: the
                // arm below is the only thing that touches timer state, and it never ran.
                store.updateHud(id, spec: previous,
                                size: HudPanelSize(widthPercent: previousSize, heightPercent: previousHeight),
                                paneIdentity: previousPaneIdentity)
                return ControlResponse(ok: false, error: OverlayHudError.writeFailed)
            }
            self.armHudAutoHide(session, spec: spec)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// The body file goes with the state: `Session.discardHudBody` deletes it inside the store, so every
    /// close — this one, `overlay close`, ⌘W, session and window teardown — removes it whether or not the
    /// panel's surface ever realized.
    func closeHud(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard store.closeHud(id) else {
                return ControlResponse(ok: false, error: OverlayHudError.noHud)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// The terminal's padding inside the panel, per side, from `Resources/ghostty-defaults.conf`
    /// (`window-padding-x = 8`, `window-padding-y = 6`). It holds no cells, so the grid the helper centers
    /// in owes it two columns and two rows. A user `ghostty.conf` overriding either is not tracked and
    /// shifts the centering by about a column, as the estimated cell already can.
    private static let windowPadding = (horizontal: 8.0, vertical: 6.0)

    /// watchHudGeometry coalesces deck size notifications into body rewrites using the latest HUD state.
    func watchHudGeometry(_ session: Session) {
        let id = session.id
        session.onHudGeometryChange = { [weak self, weak session] in
            guard let self, self.hudGeometryPending.insert(id).inserted else { return }
            Task { @MainActor [weak self, weak session] in
                guard let self else { return }
                self.hudGeometryPending.remove(id)
                guard let session, session.hudActive else { return }
                _ = self.writeHudBody(session, pane: self.paneMetrics(for: session, pane: session.hudTargetPane,
                                                                    fontSize: self.liveHudFontSize(session)))
            }
        }
    }

    /// liveHudFontSize is the size the live HUD's surface was created at.
    func liveHudFontSize(_ session: Session) -> Double {
        session.hudFontSize ?? session.fontSize ?? GhosttyApp.shared.baseFontSize
    }

    /// paneMetrics measures the cell from `fontSize`, the HUD surface's own. A scoped call reads the deck-frame cache, falling back to its
    /// deck-hosted surface before the preference arrives; zoom and dashboard hosts are excluded. An unscoped
    /// call unions the live pane frames, so a hidden focused split contributes its one maximized surface.
    /// libghostty reports no cell metrics; an unmeasured session takes the cap.
    func paneMetrics(for session: Session, pane: OverlayPane? = nil, fontSize: Double) -> PaneMetrics {
        let cell = Self.cellSize(family: settingsModel.settings.fontFamily, size: fontSize)
        let size: (width: Double, height: Double)
        if let pane, let frame = session.hudPaneFrames[pane] {
            size = (frame.width, frame.height)
        } else if let pane {
            let surface = pane == .left ? session.surface : session.splitSurface
            if let view = surface as? GhosttySurfaceView,
               view.window != nil, !view.suppressFocusChange {
                let frame = view.convert(view.bounds, to: nil)
                size = (frame.width, frame.height)
            } else {
                size = (0, 0)
            }
        } else {
            let frames = [session.surface, session.splitSurface]
                .compactMap { $0 as? GhosttySurfaceView }
                .filter { $0.window != nil }
                .map { $0.convert($0.bounds, to: nil) }
            let area = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
            size = (area.width, area.height)
        }
        return PaneMetrics(cellWidth: cell.width, cellHeight: cell.height,
                           paneWidth: size.width, paneHeight: size.height,
                           paddingWidth: Self.windowPadding.horizontal,
                           paddingHeight: Self.windowPadding.vertical)
    }

    /// One cell of `family` at `size`: the horizontal advance of a digit (every glyph advances the same in
    /// a monospaced face) and ascent + descent + leading for the line box. An unresolvable family falls
    /// back to the system monospaced face rather than to a guessed ratio.
    static func cellSize(family: String?, size: Double) -> (width: Double, height: Double) {
        let font = family.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        var characters: [UniChar] = Array("0".utf16)
        var glyph = CGGlyph()
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(font, &characters, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        } else {
            // a face with no glyph for "0" would otherwise leave the advance at zero and drive every panel to
            // the clamp's floor with nothing to explain it
            NSLog("hud: no digit glyph in %@, falling back to a one-point cell", font.fontName)
        }
        let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return (width: max(advance.width, 1), height: max(height, 1))
    }

    /// The eval'd command line for the bundled painter, nil when the build did not bundle it. Run through
    /// `/bin/sh` so a resource copy that dropped the executable bit still starts, and shell-escaped because
    /// the wrapper `eval`s this line.
    static func helperCommand() -> String? {
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("hud/hud.sh"),
              FileManager.default.isReadableFile(atPath: helper.path) else { return nil }
        return "/bin/sh \(ShellEscape.path(helper.path))"
    }

    /// One body file per session, so an update rewrites the path the running helper already opened and a
    /// replacement reuses it instead of leaking a temp file per open.
    static func bodyFile(for sessionID: UUID) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-hud-\(sessionID.uuidString).txt")
    }

    /// Writes the live HUD's body ATOMICALLY (temp file plus rename): the helper re-reads it every tick with
    /// no locking, so a partial write would paint half a message. Every state the header carries — the
    /// fields `HudLayout.renderedBody` owns — is read off the session, so the grid is the one the panel
    /// ACTUALLY took and open, update and resize cannot write three different answers.
    ///
    /// False for a session with no HUD up, and for a write the file system refused — both leave the panel
    /// painting whatever it last read, which is why every caller rolls its store change back.
    func writeHudBody(_ session: Session, pane: PaneMetrics) -> Bool {
        guard let path = session.hudFile, let spec = session.hudSpec,
              let size = session.overlaySizePercent, let height = session.hudHeightPercent else { return false }
        let grid = HudLayout.paintGrid(for: spec, size: HudPanelSize(widthPercent: size, heightPercent: height),
                                       pane: pane)
        let rendered = HudLayout.renderedBody(for: spec, grid: grid,
                                              ownerPid: ProcessInfo.processInfo.processIdentifier)
        return (try? Data(rendered.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
