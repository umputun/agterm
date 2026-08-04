import AppKit
import CoreText
import Foundation
import agtermCore

/// App-side host for `session.hud.*`. Validation, error text and response shape stay in
/// `ControlDispatcher+Hud`; this layer supplies the three things agtermCore cannot resolve — the bundled
/// helper's path, the terminal font's cell size, and the pane's live geometry — plus the body file the
/// helper reads.
extension ControlServer {
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            guard let command = Self.helperCommand() else {
                return ControlResponse(ok: false, error: "hud helper is not bundled in this build")
            }
            let file = Self.bodyFile(for: id)
            // measured ONCE and threaded through: the sizing and the header describe the same panel, and
            // both a font lookup and a pane-geometry union would otherwise run twice per command.
            let metrics = self.paneMetrics(for: session)
            // open FIRST, write second: replacing a live HUD tears its surface down, and that teardown
            // deletes the body file at this same per-session path — writing first would lose it. The
            // header's grid also comes from the size the store RESOLVED, which only exists after this call.
            guard store.openHud(id, command: command, spec: spec, file: file,
                                size: HudLayout.panelSize(for: spec, pane: metrics)) else {
                return ControlResponse(ok: false, error: "overlay already open")
            }
            // the rolled-back HUD never realized a surface, and a replaced predecessor's file sits at this
            // same path: `Session.discardHudBody`, which `closeHud` routes through, deletes both.
            guard self.writeHudBody(session, pane: metrics) else {
                store.closeHud(id)
                return ControlResponse(ok: false, error: OverlayHudError.writeFailed)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Rewrites the live HUD's body and re-sizes the panel in place, repainting with no re-spawn per
    /// `HudLayout.renderedBody`. A failed write rolls the store back, as `openHud` does with `closeHud`:
    /// the panel still paints the old message, and `tree` must not claim the new one.
    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            // `hudActive` is the occupancy question, asked once and separately from the mutation below, so
            // a store that refused for another reason cannot come back as `noHud`.
            guard let session = store.session(withID: id), session.hudActive,
                  let previous = session.hudSpec, let previousSize = session.overlaySizePercent,
                  let previousHeight = session.hudHeightPercent else {
                return ControlResponse(ok: false, error: OverlayHudError.noHud)
            }
            let metrics = self.paneMetrics(for: session)
            store.updateHud(id, spec: spec, size: HudLayout.panelSize(for: spec, pane: metrics))
            guard self.writeHudBody(session, pane: metrics) else {
                store.updateHud(id, spec: previous,
                                size: HudPanelSize(widthPercent: previousSize, heightPercent: previousHeight))
                return ControlResponse(ok: false, error: OverlayHudError.writeFailed)
            }
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

    /// Cell size from the CONFIGURED terminal font (the session's own size override, else the Settings
    /// base) and pane size from the surfaces currently laid out. libghostty reports no cell metrics —
    /// `GHOSTTY_ACTION_CELL_SIZE` discards its payload — so this measurement may round differently from the
    /// cell it actually renders. That divergence is ACCEPTED, not corrected: the min/max clamp only bounds
    /// the percentage, so a wider real cell overruns the helper's centering by a column or two. A session
    /// with nothing on screen measures zero and takes the clamp's maximum.
    func paneMetrics(for session: Session) -> PaneMetrics {
        let cell = Self.cellSize(family: settingsModel.settings.fontFamily,
                                 size: session.fontSize ?? GhosttyApp.shared.baseFontSize)
        // the panel is laid out over the whole detail area, so the pane is the union of the laid-out panes:
        // a hidden-but-focused split shows one pane maximized, and only the one in a window measures right.
        let frames = [session.surface, session.splitSurface]
            .compactMap { $0 as? GhosttySurfaceView }
            .filter { $0.window != nil }
            .map { $0.convert($0.bounds, to: nil) }
        let area = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
        return PaneMetrics(cellWidth: cell.width, cellHeight: cell.height,
                           paneWidth: area.width, paneHeight: area.height,
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
