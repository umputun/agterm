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
            // open FIRST, write second: replacing a live HUD tears its surface down, and that teardown
            // deletes the body file at this same per-session path — writing first would lose it.
            guard store.openHud(id, command: command, spec: spec, file: file,
                                sizePercent: self.sizePercent(for: spec, session: session)) else {
                return ControlResponse(ok: false, error: "overlay already open")
            }
            guard Self.writeBody(spec, to: file) else {
                store.closeHud(id)
                return ControlResponse(ok: false, error: "could not write the hud message")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Rewrites the live HUD's body and re-sizes the panel in place. The helper re-reads the file every
    /// tick — box and spinner included, they ride in its header line — so nothing re-spawns and the panel
    /// does not blink.
    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard let session = store.session(withID: id), let file = session.hudFile else {
                return ControlResponse(ok: false, error: "no hud")
            }
            guard store.updateHud(id, spec: spec, file: file,
                                  sizePercent: self.sizePercent(for: spec, session: session)) else {
                return ControlResponse(ok: false, error: "no hud")
            }
            guard Self.writeBody(spec, to: file) else {
                return ControlResponse(ok: false, error: "could not write the hud message")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func closeHud(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            let file = store.session(withID: id)?.hudFile
            guard store.closeHud(id) else {
                return ControlResponse(ok: false, error: "no hud")
            }
            // the surface's own teardown removes this, but a HUD whose surface never realized has none.
            if let file { try? FileManager.default.removeItem(atPath: file) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// The share of the pane the panel takes: the caller's `--size-percent` when set, else the message's
    /// own cell box measured against the session's font and live pane geometry.
    private func sizePercent(for spec: HudSpec, session: Session) -> Int {
        if let requested = spec.sizePercent { return requested }
        return HudLayout.sizePercent(box: HudLayout.box(for: spec), pane: paneMetrics(for: session))
    }

    /// Cell size from the CONFIGURED terminal font (the session's own size override, else the Settings
    /// base) and pane size from the surfaces currently laid out. libghostty reports no cell metrics —
    /// `GHOSTTY_ACTION_CELL_SIZE` discards its payload — and its own cell width may round differently, which
    /// `HudLayout`'s min/max clamp absorbs. A session with nothing on screen measures zero and takes the
    /// clamp's maximum.
    private func paneMetrics(for session: Session) -> PaneMetrics {
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
                           paneWidth: area.width, paneHeight: area.height)
    }

    /// One cell of `family` at `size`: the horizontal advance of a digit (every glyph advances the same in
    /// a monospaced face) and ascent + descent + leading for the line box. An unresolvable family falls
    /// back to the system monospaced face rather than to a guessed ratio.
    private static func cellSize(family: String?, size: Double) -> (width: Double, height: Double) {
        let font = family.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        var characters: [UniChar] = Array("0".utf16)
        var glyph = CGGlyph()
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(font, &characters, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
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

    /// One body file per session, so an update rewrites the path the running helper already opened (its
    /// environment cannot change) and a replacement reuses it instead of leaking a temp file per open.
    static func bodyFile(for sessionID: UUID) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-hud-\(sessionID.uuidString).txt")
    }

    /// Writes the rendered body ATOMICALLY (temp file plus rename): the helper re-reads it every tick with
    /// no locking, so a partial write would paint half a message. The header carries THIS process's pid,
    /// which is the only stop a painter has when the app is hard-killed and runs no teardown.
    private static func writeBody(_ spec: HudSpec, to path: String) -> Bool {
        let body = Data(HudLayout.renderedBody(for: spec, ownerPid: ProcessInfo.processInfo.processIdentifier).utf8)
        return (try? body.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
