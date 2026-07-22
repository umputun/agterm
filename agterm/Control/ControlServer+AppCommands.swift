import Foundation
import agtermCore

/// `ControlServer` APP-GLOBAL action adapter arms — the ones that take no session/workspace target and
/// act on a whole window or the app itself: the `tree` projection, the sidebar visibility/view-mode and
/// expand/collapse arms, keymap + ghostty-config reload, the theme slots, and the per-window quick
/// terminal. Split out of `ControlServer+SessionActions.swift` (which keeps the session-, workspace-, and
/// surface-scoped arms) to keep both files under the swiftlint size limit.
extension ControlServer {
    func controlTree(window: String?) -> ControlResponse {
        resolver.resolvePlacementStore(window) { store in
            ControlResponse(ok: true, result: ControlResult(tree: buildTree(in: store)))
        }
    }

    func readEvents(_ options: ControlEventReadOptions) -> ControlResponse {
        library.readEvents(options)
    }

    // MARK: - Sidebar

    /// Show / hide / toggle the frontmost window's sidebar (the custom split owns visibility, so there's
    /// no system toggle). Flips only when the requested state differs; an unknown mode is an error, and no
    /// open window is an error rather than a silent no-op.
    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse {
        guard let store = library.activeStore else {
            return ControlResponse(ok: false, error: "no open window")
        }
        let want = mode.desiredValue(current: store.sidebarVisible)
        store.setSidebarVisible(want) // no-op + no save when unchanged (idempotent)
        return ControlResponse(ok: true)
    }

    /// Set the frontmost window's sidebar VIEW mode (the tree vs the flat flagged list) — distinct from
    /// `setSidebarVisibility`. `mode` is `tree|flagged|toggle`, delta-computed so a no-op mode skips
    /// the write (idempotent), via `AppStore.setSidebarMode`. An unknown mode + no-open-window are errors.
    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse {
        guard let store = library.activeStore else {
            return ControlResponse(ok: false, error: "no open window")
        }
        let want: SidebarMode
        switch mode {
        case .tree: want = .tree
        case .flagged: want = .flagged
        case .toggle: want = store.sidebarMode == .tree ? .flagged : .tree
        }
        store.setSidebarMode(want) // no-op + no save when unchanged (idempotent)
        return ControlResponse(ok: true)
    }

    /// Expand every workspace in a window's sidebar tree — the `--window` selector picks the (OPEN) target,
    /// defaulting to the frontmost window (a graceful no-op in flagged mode, which has no workspace rows).
    /// Drives `AppActions.expandAllWorkspaces(in:)` (the same path the View menu / palette drive on the
    /// frontmost). Idempotent (expanding when all are already expanded is a clean no-op); a named-but-closed
    /// window errors, and no open window at all errors rather than silently no-opping.
    func expandSidebar(window: String?) -> ControlResponse {
        if trimmed(window) == nil, library.activeStore == nil {
            return ControlResponse(ok: false, error: "no open window")
        }
        return resolver.resolvePlacementStore(window) { store in
            actions.expandAllWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }

    /// Collapse every workspace except the active one (the active session's workspace) in a window's
    /// sidebar, keeping that workspace expanded and scrolled into view. The `--window` selector picks the
    /// (OPEN) target, defaulting to the frontmost. Drives `AppActions.collapseOtherWorkspaces(in:)`.
    /// Graceful no-op in flagged mode; idempotent; a named-but-closed window errors, and no open window
    /// at all errors.
    func collapseSidebar(window: String?) -> ControlResponse {
        if trimmed(window) == nil, library.activeStore == nil {
            return ControlResponse(ok: false, error: "no open window")
        }
        return resolver.resolvePlacementStore(window) { store in
            actions.collapseOtherWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }

    // MARK: - Keymap

    /// Re-read and re-parse `keymap.conf`, returning the count of parse diagnostics. The SAME
    /// `reloadKeymap()` path the GUI's File ▸ Reload Keymap menu/palette item drives, so the menu/palette
    /// and `keymap.reload` never diverge — control-native here only in the count it reports back.
    func reloadKeymap() -> ControlResponse {
        settingsModel.reloadKeymap()
        return ControlResponse(ok: true, result: ControlResult(count: settingsModel.keymapDiagnostics.count))
    }

    // MARK: - Config

    /// Re-read and apply the ghostty config, returning the config-diagnostic count (0 = clean), counted
    /// across ALL config sources (bundled defaults, the global `~/.config/ghostty/config`, the agterm-scoped
    /// `ghostty.conf`, and the UI settings conf) — libghostty diagnostics carry no source-file attribution.
    /// The SAME `AppActions.reloadGhosttyConfig()` path the GUI's File ▸ Reload Config menu/palette item
    /// drives (which posts the warning banner on diagnostics), so the GUI and `config.reload` never diverge
    /// — control-native here only in the count it reports back. The count is the value the reload actually
    /// produced (threaded back from the reload), not a separate re-read. App-global (one settings model +
    /// one GhosttyApp), so no `--window` selector, like `keymap.reload`.
    func reloadGhosttyConfig() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(count: actions.reloadGhosttyConfig()))
    }

    // MARK: - Theme

    /// Set + persist a theme PER SLOT — the control half of the Settings pickers / the `.themes` palette
    /// commit (no live preview over the socket). `args.name` (alias `args.light`; both is an error) sets the
    /// light/single slot, keeping any dark slot; `args.dark` sets the dark slot and turns macOS-appearance
    /// syncing ON (the stored value becomes ghostty's dual `light:,dark:`, light side seeded), and the
    /// reserved value `none` (any case) clears it (syncing off). A nil/empty name selects ghostty's built-in colors
    /// ("default ghostty"), NOT the seeded `agterm` app default; any other name must be a bundled theme, else
    /// an error (a typo silently doing nothing is worse than a fail). Echoes the full post-change state
    /// (`theme`/`sync`/`light`/`dark`). App-global: one `SettingsModel`, so no `--window` selector.
    func setTheme(args: ControlArgs?) -> ControlResponse {
        let name = ThemeCatalog.resolvedName(args?.name)
        let light = ThemeCatalog.resolvedName(args?.light)
        let dark = ThemeCatalog.resolvedName(args?.dark)
        if name != nil && light != nil {
            return ControlResponse(ok: false, error: "theme.set takes either a name or --light, not both")
        }
        let lightSlot = name ?? light
        let clearDark = dark?.lowercased() == "none"
        let catalog = ThemeCatalog(names: actions.availableThemes())
        for theme in [lightSlot, clearDark ? nil : dark].compactMap({ $0 })
        where !catalog.contains(name: theme) {
            return ControlResponse(ok: false, error: "unknown theme: \(theme)")
        }
        if clearDark {
            actions.setDarkTheme(nil)
            if lightSlot != nil { actions.setLightTheme(lightSlot) }
        } else if let dark {
            if let lightSlot {
                actions.setSystemThemes(light: lightSlot, dark: dark)
            } else {
                actions.setDarkTheme(dark)
            }
        } else {
            actions.setLightTheme(lightSlot) // nil = bare `theme set`: reset to ghostty built-in
        }
        return ControlResponse(ok: true, result: ControlResult(
            theme: actions.currentTheme, sync: actions.followsSystemAppearance,
            light: actions.currentLightTheme, dark: actions.currentDarkTheme))
    }

    func listThemes() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(theme: actions.currentTheme,
                                                        themes: actions.availableThemes(),
                                                        sync: actions.followsSystemAppearance,
                                                        light: actions.currentLightTheme,
                                                        dark: actions.currentDarkTheme))
    }

    // MARK: - Quick terminal

    /// Show / hide / toggle the frontmost window's quick terminal (each window owns its own),
    /// flipping only when the requested state differs from the current `isVisible`. An unknown mode
    /// is an error, not a silent no-op; no open window is an error rather than a silent no-op.
    func setQuickTerminal(mode: String?) -> ControlResponse {
        guard let controller = QuickTerminalRegistry.shared.controller(for: library.activeWindowID) else {
            return ControlResponse(ok: false, error: "no open window")
        }
        guard let parsedMode = ControlToggleMode.parse(mode, on: "show", off: "hide") else {
            return ControlResponse(ok: false, error: "invalid quick mode: \(mode ?? "toggle")")
        }
        let want = parsedMode.desiredValue(current: controller.isVisible)
        if let zoom = TerminalZoomRegistry.shared.controller(for: library.activeWindowID), zoom.target != nil {
            // a script must always be able to DISMISS the quick terminal (hide was a guaranteed-ok
            // idempotent no-op pre-zoom, and cleanup code relies on that): hiding un-zooms a zoomed
            // quick terminal first, then hides it. Only SHOWING one under/over the zoom layer stays
            // blocked — that would strand an unmounted-but-visible cover.
            guard !want else {
                return ControlResponse(ok: false, error: "terminal zoom active")
            }
            if zoom.target == .quick { zoom.clear() }
            if controller.isVisible { controller.hide() }
            return ControlResponse(ok: true)
        }
        if want != controller.isVisible {
            if want { controller.show() } else { controller.hide() }
        }
        return ControlResponse(ok: true)
    }

    /// Inject `text` as literal keystrokes into the frontmost window's quick terminal, the quick-terminal
    /// twin of `session.type` (input goes where the user is typing when the overlay is up). `quick show`
    /// flips `isVisible` before SwiftUI mounts + libghostty realizes the surface, so `quick show; quick
    /// type` would otherwise race the mount — this polls briefly (like `session.type`'s realize poll) so a
    /// back-to-back script types reliably. Fails fast with `quick terminal not open` when the overlay has
    /// never been shown (no surface AND not visible), `quick terminal not realized` if a shown surface
    /// never comes up within the poll, `no open window` when there is no window.
    func typeQuick(text: String) async -> ControlResponse {
        guard let controller = QuickTerminalRegistry.shared.controller(for: library.activeWindowID) else {
            return ControlResponse(ok: false, error: "no open window")
        }
        // probe first (fast path), then sleep-then-probe up to 12 more times — a probe follows every sleep
        // so the full ~360ms window is used, matching `session.type`'s realize poll (no wasted trailing sleep).
        for attempt in 0...12 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if let surface = controller.currentSurface() {
                // a false inject means the view exists but its libghostty surface isn't realized yet — keep
                // polling rather than reporting a silent-drop false ok. A shown-then-hidden surface stays
                // alive and realized (types while hidden, like `--pane scratch`), so it lands here at once.
                if surface.inject(text: text) {
                    return ControlResponse(ok: true)
                }
            } else if !controller.isVisible {
                // no surface and not showing → never shown; don't wait out the poll.
                return ControlResponse(ok: false, error: "quick terminal not open")
            }
        }
        return ControlResponse(ok: false, error: "quick terminal not realized")
    }

    /// Read the frontmost window's quick-terminal screen as plain text, the quick-terminal twin of
    /// `session.text` — the read-back for `quick.type`. `all` reads the full screen + scrollback, `lines`
    /// keeps only the last N; the quick terminal has a single surface, so there's no `--pane`. Polls for
    /// mount + realization like `typeQuick` so `quick show; quick text` doesn't race the mount; fails fast
    /// with `quick terminal not open` when never shown, `failed to read surface buffer` if a shown surface
    /// never realizes within the poll, `no open window` when there is no window.
    func readQuickText(all: Bool, lines: Int?) async -> ControlResponse {
        guard let controller = QuickTerminalRegistry.shared.controller(for: library.activeWindowID) else {
            return ControlResponse(ok: false, error: "no open window")
        }
        // probe first, then sleep-then-probe up to 12 more times (a probe follows every sleep), like `typeQuick`.
        for attempt in 0...12 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if let surface = controller.currentSurface() {
                // readScreenText returns nil only for an unrealized surface ("" for a realized blank
                // screen), so a non-nil result means the surface is up — return it.
                if let text = surface.readScreenText(all: all, lines: lines) {
                    return ControlResponse(ok: true, result: ControlResult(text: text))
                }
            } else if !controller.isVisible {
                return ControlResponse(ok: false, error: "quick terminal not open")
            }
        }
        return ControlResponse(ok: false, error: "failed to read surface buffer")
    }
}
