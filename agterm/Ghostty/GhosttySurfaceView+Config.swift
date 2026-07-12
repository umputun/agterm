// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    // MARK: - Surface config

    /// Applies a rebuilt ghostty config to this live surface (font/theme change from Settings).
    /// `update_config` re-applies the whole config including font-size, so any runtime cmd-+/-
    /// zoom resets to the config default — the caller clears the per-session overrides to match.
    func applyConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
    }

    /// Builds this session's background-watermark config overlay (base files + `background-image*` lines +
    /// the dashboard font override else the session's current font zoom, via `WatermarkConfig`/`WatermarkRenderer`)
    /// and pushes it to the surface, retaining the config for teardown. A no-op when the surface has no owning session (the
    /// overlay/scratch/quick-terminal surfaces never carry one). A nil watermark with no font override
    /// yields the plain base config, which CLEARS a previously-applied image. The `.text` PNG is (re)rendered
    /// here so it always matches the current string/color. Main-actor; reads the session imperatively.
    func applyWatermarkFromSession() {
        guard let surface, let session else { return }
        let resolvedImagePath = WatermarkRenderer.materialize(session.backgroundWatermark, sessionID: session.id)
        let overlay = WatermarkConfig.overlayText(watermark: session.backgroundWatermark,
                                                  resolvedImagePath: resolvedImagePath, fontSize: dashboardFontOverride ?? session.fontSize,
                                                  windowOpacity: GhosttyApp.shared.windowOpacity)
        guard let config = GhosttyApp.shared.configWithOverlay(overlay) else {
            NSLog("watermark: per-surface config build failed for session %@", session.id.uuidString)
            return
        }
        ghostty_surface_update_config(surface, config)
        // free the PRIOR per-surface config(s) and keep only this one: after `update_config` installs the
        // new config the surface no longer references the old, so freeing it here is safe AND caps the
        // retain at one per surface. Without this, `config.reload` (scriptable) re-applies each watermarked
        // surface every reload and would grow `ownedConfigs` unbounded on a reload loop.
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
    }

    /// Re-assert the session's per-surface config (watermark and/or font zoom) after a global config
    /// reload broadcast the shared config to this surface via `applyConfig`, wiping both. No-op when the
    /// session carries neither (so a plain surface isn't needlessly rebuilt). Called from
    /// `GhosttyApp.reloadConfig`; on the zoom-CLEARING reload paths `session.fontSize` was already nil'd
    /// before the broadcast, so only a watermark re-applies there — the appearance-flip reload skips the
    /// reset, and this is what carries each session's zoom across the flip. It ALSO re-emits an active
    /// `dashboardFontOverride`, so a reload while the dashboard is open can't strand the transient font.
    func reapplySessionConfigIfNeeded() {
        guard session?.backgroundWatermark != nil || session?.fontSize != nil || dashboardFontOverride != nil else { return }
        applyWatermarkFromSession()
    }

    /// Re-assert a SOLID-color session background after a window-opacity change. A `.color` background
    /// bakes the current window opacity into its per-surface `background-opacity` at apply time (see
    /// `WatermarkConfig.overlayText`), so a live opacity change must re-emit it to keep the color tracking
    /// the slider. No-op unless the session carries a `.color` background — an image/text watermark has a
    /// fixed opacity and must NOT re-render (a `.text` PNG rebuild) on every opacity tick.
    func reapplyColorBackgroundIfNeeded() {
        guard session?.backgroundWatermark?.kind == .color else { return }
        applyWatermarkFromSession()
    }

    /// Applies a solid background color to a sessionless OVERLAY surface (`session.overlay.open
    /// --background-color`). Mirrors `applyWatermarkFromSession`'s `.color` path but reads the overlay's
    /// own `overlayBackgroundColorHex` + `initialFontSize` instead of a session — the overlay carries no
    /// `session`, so that path skips it. Bakes the window translucency into `background-opacity` at open
    /// time (the ephemeral overlay gets no live updates, so it does not re-track a later opacity change —
    /// unlike a session `.color`). A no-op — or a malformed hex, rejected by the leading `isValidColorHex`
    /// guard — leaves the plain base config. Retains the per-surface config in `ownedConfigs`, freed on teardown.
    func applyOverlayBackgroundColor() {
        guard let surface, let hex = overlayBackgroundColorHex, WatermarkConfig.isValidColorHex(hex) else { return }
        let overlay = WatermarkConfig.overlayText(watermark: BackgroundWatermark(kind: .color, colorHex: hex),
                                                  resolvedImagePath: nil, fontSize: initialFontSize.map(Double.init),
                                                  windowOpacity: GhosttyApp.shared.windowOpacity)
        guard let config = GhosttyApp.shared.configWithOverlay(overlay) else {
            NSLog("overlay background: per-surface config build failed")
            return
        }
        ghostty_surface_update_config(surface, config)
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
    }
}
