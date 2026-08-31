// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    // MARK: - Surface config

    /// Applies a rebuilt ghostty config to this live surface (a font/theme change from Settings).
    /// `update_config` re-applies everything including font-size, so a runtime cmd-+/- zoom resets to the
    /// config default — the caller clears the per-session overrides to match.
    func applyConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
    }

    /// Builds this session's background-watermark config overlay (base files + `background-image*` lines +
    /// `currentEffectiveFontSize()`) and pushes it to the surface, retaining the config for teardown.
    /// Scratch surfaces inherit their owner's visual config through `watermarkSession` while staying
    /// operationally sessionless; overlay and quick-terminal surfaces carry neither link. A nil watermark
    /// with no font override yields the plain base config, CLEARING a previously-applied image; the
    /// `.text` PNG is (re)rendered here to match the current string/color.
    func applyWatermarkFromSession() {
        guard let surface, let session = session ?? watermarkSession else { return }
        // this installs a config with NO OSC-11 overlay, so release the latch — it is the COLOR_CHANGE
        // dedupe key, and a stale value would swallow an identical follow-up OSC 11. the reload / opacity
        // / dashboard re-assert paths guard on the latch BEFORE calling this, so no live OSC is dropped.
        oscBackgroundColorHex = nil
        let resolvedImagePath = WatermarkRenderer.materialize(session.backgroundWatermark, sessionID: session.id)
        let overlay = WatermarkConfig.overlayText(watermark: session.backgroundWatermark,
                                                  resolvedImagePath: resolvedImagePath, fontSize: currentEffectiveFontSize(),
                                                  windowOpacity: GhosttyApp.shared.windowOpacity)
        guard let config = GhosttyApp.shared.configWithOverlay(overlay) else {
            NSLog("watermark: per-surface config build failed for session %@", session.id.uuidString)
            return
        }
        ghostty_surface_update_config(surface, config)
        // free the PRIOR per-surface configs: after `update_config` the surface no longer references them,
        // so freeing is safe and caps the retain at one. otherwise a scripted `config.reload` re-applies
        // every watermarked surface and grows `ownedConfigs` unbounded.
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
    }

    /// Re-assert the session's per-surface config (watermark and/or font zoom) after a global reload
    /// broadcast the shared config here, wiping both; a no-op when the session carries neither. The
    /// zoom-CLEARING reload paths nil `session.fontSize` first, so only a watermark re-applies there, while
    /// the appearance flip (which skips the reset) carries each session's zoom across. Also re-emits an
    /// active `dashboardFontOverride`, so a reload with the dashboard open can't strand the transient font.
    func reapplySessionConfigIfNeeded() {
        // a transient OSC-11 background wins over the persisted watermark and must survive the reload
        // broadcast that wiped it.
        if let hex = oscBackgroundColorHex { applyOSCBackground(hex); return }
        let configSession = session ?? watermarkSession
        guard configSession?.backgroundWatermark != nil || configSession?.fontSize != nil || dashboardFontOverride != nil else {
            return
        }
        applyWatermarkFromSession()
    }

    /// Re-assert a SOLID-color session background after a window-opacity change: a `.color` background
    /// bakes the window opacity into its per-surface `background-opacity` at apply time, so a live change
    /// must re-emit to keep tracking the slider. No-op otherwise — an image/text watermark has a fixed
    /// opacity and must NOT re-render its PNG on every opacity tick.
    func reapplyColorBackgroundIfNeeded() {
        // an OSC-11 background bakes the opacity like a `.color` watermark, so it must re-emit too.
        if let hex = oscBackgroundColorHex { applyOSCBackground(hex); return }
        guard (session ?? watermarkSession)?.backgroundWatermark?.kind == .color else { return }
        applyWatermarkFromSession()
    }

    /// Applies a solid background color to a sessionless OVERLAY surface (`session.overlay.open
    /// --background-color`), reading the overlay's own `overlayBackgroundColorHex` since it carries no
    /// `session`. Bakes the window translucency into `background-opacity` at open time — the ephemeral
    /// overlay gets no live updates, so unlike a session `.color` it does not re-track a later opacity
    /// change. A rejected (malformed) hex leaves the plain base config.
    func applyOverlayBackgroundColor() {
        guard let surface, let hex = overlayBackgroundColorHex, WatermarkConfig.isValidColorHex(hex) else { return }
        let overlay = WatermarkConfig.overlayText(watermark: BackgroundWatermark(kind: .color, colorHex: hex),
                                                  resolvedImagePath: nil, fontSize: currentEffectiveFontSize(),
                                                  windowOpacity: GhosttyApp.shared.windowOpacity)
        guard let config = GhosttyApp.shared.configWithOverlay(overlay) else {
            NSLog("overlay background: per-surface config build failed")
            return
        }
        ghostty_surface_update_config(surface, config)
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
    }

    /// Route a dynamic background color libghostty reported for THIS surface (`GHOSTTY_ACTION_COLOR_CHANGE`,
    /// kind background). The action carries no set-vs-reset flag — OSC 111 just reports the terminal's
    /// default background — so the surface's own baseline identifies a reset. `OSCBackgroundPolicy` owns
    /// the decision and the per-prompt dedupe.
    func handleOSCBackgroundChange(_ hex: String) {
        switch OSCBackgroundPolicy.decide(incoming: hex, themeBackground: baselineBackgroundHex(),
                                          current: oscBackgroundColorHex) {
        case .apply(let color): applyOSCBackground(color)
        case .reset: releaseOSCBackground()
        case .ignore: break
        }
    }

    /// What ghostty seeded the terminal's `default` color layer from when it last took this surface's
    /// config — the color a reported change must equal to count as a reset. `OSCBackgroundPolicy.baseline`
    /// owns the rule, including why an installed OSC overlay makes it the theme rather than this surface's
    /// own color; here we only gather its two inputs.
    private func baselineBackgroundHex() -> String? {
        OSCBackgroundPolicy.baseline(oscOverlayActive: oscBackgroundColorHex != nil,
                                     surfaceBackground: surfaceOwnBackgroundHex(),
                                     themeBackground: GhosttyApp.shared.terminalBackgroundColor?.agtermHexString)
    }

    /// The background color this surface's OWN config carries: a `.color` session watermark, else a
    /// sessionless overlay's `--background-color`. Nil when the surface runs the plain base config.
    private func surfaceOwnBackgroundHex() -> String? {
        if let watermark = (session ?? watermarkSession)?.backgroundWatermark, watermark.kind == .color,
           let hex = watermark.colorHex {
            return hex
        }
        return overlayBackgroundColorHex
    }

    /// Apply the dynamic background color a program set on THIS surface via OSC 11. libghostty already
    /// stored it in the terminal's dynamic `override` layer and the renderer draws `override orelse
    /// default`, so the color needs no restating — but under window translucency the surface renders
    /// `background-opacity = 0` (the AppKit window backing supplies the tint), which hides it. The overlay
    /// here lifts the opacity back to the window's, so the pane tints itself honoring the slider, leaving
    /// the window backing, the chrome and every other surface alone.
    ///
    /// It deliberately carries NO `background` key: that would re-seed the terminal's `default` color layer
    /// with the OSC color, and since OSC 111 resets the override TO that default, the program's own reset
    /// would restore its color and strand the pane recolored (issue #309).
    func applyOSCBackground(_ hex: String) {
        guard let surface, WatermarkConfig.isValidColorHex(hex) else { return }
        oscBackgroundColorHex = hex
        let overlay = WatermarkConfig.oscBackgroundOverlayText(fontSize: currentEffectiveFontSize(),
                                                               windowOpacity: GhosttyApp.shared.windowOpacity)
        guard let config = GhosttyApp.shared.configWithOverlay(overlay) else {
            NSLog("osc background: per-surface config build failed")
            return
        }
        ghostty_surface_update_config(surface, config)
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
    }

    /// Drop this surface's OSC-11 overlay after a program reset the dynamic background, falling back to the
    /// surface's own baseline config — the session's watermark/zoom, a sessionless overlay's
    /// `--background-color`, else the plain config with the live font zoom preserved. libghostty has
    /// already restored its `override` to the default color, so this only takes the opacity lift away.
    func releaseOSCBackground() {
        oscBackgroundColorHex = nil
        if session != nil || watermarkSession != nil { applyWatermarkFromSession(); return }
        if overlayBackgroundColorHex != nil { applyOverlayBackgroundColor(); return }
        guard let surface else { return }
        let overlay = WatermarkConfig.overlayText(watermark: nil, resolvedImagePath: nil,
                                                  fontSize: currentEffectiveFontSize())
        guard let config = GhosttyApp.shared.configWithOverlay(overlay) else {
            NSLog("osc background: per-surface config rebuild failed on reset")
            return
        }
        ghostty_surface_update_config(surface, config)
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
    }

    /// The font size every per-surface config re-apply must restate so it doesn't reset the pane's zoom:
    /// the dashboard's transient override, else the session's zoom, else a sessionless surface's live
    /// cmd-+/- size, else its creation size. A split-role or scratch pane's zoom is never persisted and is
    /// readable only from the surface (see `ControlServer+SurfaceIO.font`), so restating `session.fontSize` or an
    /// overlay's creation size snaps such a pane back on
    /// every re-apply (a `session.background` set/clear, an OSC reset).
    private func currentEffectiveFontSize() -> Double? {
        dashboardFontOverride ?? session?.fontSize ?? currentFontSize() ?? initialFontSize.map(Double.init)
    }
}
