import AppKit
import Foundation
import agtermCore

/// `ControlServer` APP-GLOBAL action adapter arms — no session/workspace target, acting on a whole window or
/// the app: the `tree` projection, sidebar visibility/view-mode and expand/collapse, keymap +
/// ghostty-config reload, the theme slots, and the per-window quick terminal. Split out of
/// `ControlServer+SessionActions.swift` (session-, workspace- and surface-scoped) for the file size limit.
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

    /// Show / hide / toggle the frontmost window's sidebar (the custom split owns visibility — no system
    /// toggle). Flips only on a differing state; unknown mode and no open window are errors, not no-ops.
    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse {
        guard let store = library.activeStore else {
            return ControlResponse(ok: false, error: "no open window")
        }
        let want = mode.desiredValue(current: store.sidebarVisible)
        store.setSidebarVisible(want)
        return ControlResponse(ok: true)
    }

    /// Set the frontmost window's sidebar VIEW mode (tree vs the flat flagged list), distinct from
    /// `setSidebarVisibility`. Delta-computed so a no-op mode skips the write; unknown mode + no window error.
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
        store.setSidebarMode(want)
        return ControlResponse(ok: true)
    }

    /// Expand every workspace in a window's sidebar tree; `--window` picks the OPEN target, default frontmost.
    /// Graceful no-op in flagged mode (no workspace rows) and idempotent. Drives the same
    /// `AppActions.expandAllWorkspaces(in:)` the View menu / palette drive; a closed or absent window errors.
    func expandSidebar(window: String?) -> ControlResponse {
        resolver.resolveOpenPlacementStore(window) { store in
            actions.expandAllWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }

    /// Collapse every workspace except the active session's, which stays expanded and scrolled into view.
    /// `--window` picks the OPEN target, default frontmost. Drives `AppActions.collapseOtherWorkspaces(in:)`;
    /// graceful no-op in flagged mode, idempotent, and a closed or absent window errors.
    func collapseSidebar(window: String?) -> ControlResponse {
        resolver.resolveOpenPlacementStore(window) { store in
            actions.collapseOtherWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }

    // MARK: - Keymap

    /// Re-read and re-parse `keymap.conf`, returning the parse-diagnostic count. The SAME `reloadKeymap()`
    /// path File ▸ Reload Keymap drives, so the two can't diverge — only the reported count is control-native.
    func reloadKeymap() -> ControlResponse {
        settingsModel.reloadKeymap()
        return ControlResponse(ok: true, result: ControlResult(count: settingsModel.keymapDiagnostics.count))
    }

    /// The read side of `keymap.reload`: what the keymap resolved, plus what the menu bar is dispatching. The
    /// two can disagree — SwiftUI defers its menu rebuild to the next app activation, so a chord correct in
    /// the model can be stale in the menu. App-global like `keymap.reload`, so no `--window` selector.
    func listKeymap() -> ControlResponse {
        let payload = ControlKeymap.project(keymap: settingsModel.keymap,
                                            diagnostics: settingsModel.keymapDiagnostics,
                                            path: settingsModel.keymapPath,
                                            menu: ControlServer.liveMenuKeyEquivalents())
        return ControlResponse(ok: true, result: ControlResult(keymap: payload))
    }

    /// Every menu-bar item carrying a key equivalent, in the same kitty syntax the keymap uses so a caller can
    /// compare the lists. Only the app target reads `NSApp.mainMenu`, so this is `keymap.list`'s app-side half.
    @MainActor
    private static func liveMenuKeyEquivalents() -> [ControlKeymapMenuItem] {
        (NSApp.mainMenu?.items ?? []).flatMap { topItem in
            topItem.submenu.map { collectKeyEquivalents(in: $0, menu: topItem.title) } ?? []
        }
    }

    /// Every key equivalent in `submenu`, RECURSING into nested submenus. AppKit's `performKeyEquivalent`
    /// recurses, so a nested chord is just as live and can shadow an agterm binding — App ▸ Services is the
    /// reachable case, carrying whatever shortcuts the user assigned in System Settings. Top-level-only
    /// reporting would let a caller conclude nothing holds a chord when something does.
    ///
    /// `menu` stays the TOP-LEVEL title throughout, so a nested item is attributed to the menu-bar entry the
    /// reader can find it under. Internal rather than private so `CloseSessionChordTests`' companion can drive
    /// it over a hand-built nested menu: agterm's own submenus carry no key equivalents and Services entries
    /// depend on the user's system settings, so no nested chord exists for an e2e to assert against.
    @MainActor
    static func collectKeyEquivalents(in submenu: NSMenu, menu: String) -> [ControlKeymapMenuItem] {
        submenu.items.flatMap { item -> [ControlKeymapMenuItem] in
            var found: [ControlKeymapMenuItem] = []
            if !item.keyEquivalent.isEmpty {
                found.append(ControlKeymapMenuItem(menu: menu, title: item.title,
                                                   chord: chordSyntax(for: item),
                                                   selector: item.action.map(NSStringFromSelector),
                                                   enabled: item.isEnabled ? nil : false))
            }
            if let nested = item.submenu { found += collectKeyEquivalents(in: nested, menu: menu) }
            return found
        }
    }

    /// An `NSMenuItem`'s key equivalent in kitty syntax (`cmd+shift+e`), in `Chord.displayString`'s modifier
    /// order so the two render identically and compare as strings.
    ///
    /// Two AppKit spellings must be translated or the chord is uncomparable. Arrows and return/tab/space/delete
    /// arrive as function-key or control CHARACTERS, rendering the key blank (`cmd+opt+` for the keymap's
    /// `cmd+opt+up`), so they go through `namedKey(forKeyEquivalent:)`; a shift-typed equivalent arrives as the
    /// SHIFTED character with `.shift` set (⇧E is `"E"`), so an ordinary key is lowercased to the grammar's base.
    ///
    /// The globe/fn modifier has no keymap spelling (the grammar knows ctrl/cmd/opt/shift only) but renders as
    /// `fn+` anyway: this reports what the menu bar carries, and dropping it would print AppKit's ⌥⌘F-style
    /// items as bare unmodified keys, reading as a binding that does not exist. A `fn+` chord never matches an
    /// action's chord, which is correct.
    @MainActor
    private static func chordSyntax(for item: NSMenuItem) -> String {
        let mods = item.keyEquivalentModifierMask
        let key = item.keyEquivalent
        // an UPPERCASE key equivalent carries shift implicitly whatever the mask says: AppKit matches `"C"` +
        // [.command] against ⇧⌘C, not ⌘C. agterm's own items never spell it that way (`toShortcut` puts shift
        // in the mask), but this walk reports third-party items, where lowercasing would name an unfirable chord.
        let impliedShift = key.count == 1 && key.first?.isUppercase == true
        var parts: [String] = []
        if mods.contains(.function) { parts.append("fn") }
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.command) { parts.append("cmd") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) || impliedShift { parts.append("shift") }
        parts.append(namedKey(forKeyEquivalent: key) ?? key.lowercased())
        return parts.joined(separator: "+")
    }

    // MARK: - Config

    /// Re-read and apply the ghostty config, returning the diagnostic count (0 = clean) across ALL sources
    /// (bundled defaults, `~/.config/ghostty/config`, the agterm-scoped `ghostty.conf`, the UI settings conf)
    /// — libghostty diagnostics carry no source-file attribution. The SAME `AppActions.reloadGhosttyConfig()`
    /// File ▸ Reload Config drives (posting the warning banner), so the two can't diverge; the count is what
    /// that reload produced, not a re-read. App-global (one settings model + one GhosttyApp), so no `--window`.
    func reloadGhosttyConfig() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(count: actions.reloadGhosttyConfig()))
    }

    // MARK: - Theme

    /// Set + persist a theme PER SLOT — the control half of the Settings pickers / `.themes` palette commit
    /// (no live preview over the socket). `args.name` (alias `args.light`; both is an error) sets the
    /// light/single slot, keeping any dark one; `args.dark` sets the dark slot and turns macOS-appearance
    /// syncing ON (the stored value becomes ghostty's dual `light:,dark:`, light side seeded), and `none`
    /// (any case) clears it, syncing off. A nil/empty name picks ghostty's built-in colors ("default ghostty"),
    /// NOT the seeded `agterm` default; any other name must be a bundled theme, else an error (a typo doing
    /// nothing silently is worse). Echoes `theme`/`sync`/`light`/`dark`. App-global, so no `--window`.
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

    /// Show / hide / toggle the frontmost window's quick terminal (each window owns one), flipping only when
    /// the state differs from `isVisible`. Unknown mode and no open window are errors, not silent no-ops.
    func setQuickTerminal(mode: String?) -> ControlResponse {
        guard let controller = QuickTerminalRegistry.shared.controller(for: library.activeWindowID) else {
            return ControlResponse(ok: false, error: "no open window")
        }
        guard let parsedMode = ControlToggleMode.parse(mode, on: "show", off: "hide") else {
            return ControlResponse(ok: false, error: "invalid quick mode: \(mode ?? "toggle")")
        }
        let want = parsedMode.desiredValue(current: controller.isVisible)
        if want, !controller.isVisible,
           PickRegistry.shared.controller(for: library.activeWindowID)?.pending != nil {
            return ControlResponse(ok: false, error: "pick pending")
        }
        if let zoom = TerminalZoomRegistry.shared.controller(for: library.activeWindowID), zoom.target != nil {
            // a script must always be able to DISMISS the quick terminal — hide is a guaranteed-ok idempotent
            // no-op cleanup code relies on — so hiding un-zooms a zoomed one first, then hides. only SHOWING
            // one under/over the zoom layer stays blocked, which would strand an unmounted-but-visible cover.
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

    /// Inject `text` as literal keystrokes into the frontmost window's quick terminal, the twin of
    /// `session.type` (input goes where the user is typing while the overlay is up). `quick show` flips
    /// `isVisible` before SwiftUI mounts + libghostty realizes the surface, so this polls briefly (like
    /// `session.type`'s realize poll) rather than racing a back-to-back `quick show; quick type`. Fails fast
    /// with `quick terminal not open` when never shown (no surface AND not visible), `quick terminal not
    /// realized` if a shown surface never comes up within the poll, `no open window` when there is no window.
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
                // a false inject means the view exists but its surface isn't realized — keep polling, don't
                // report a silent-drop ok. a shown-then-hidden surface stays alive and realized, typing while
                // hidden like `--pane scratch`, so it lands here at once.
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

    /// Read the frontmost window's quick-terminal screen as plain text, the twin of `session.text` and the
    /// read-back for `quick.type`. `all` adds scrollback, `lines` keeps the last N; one surface, so no
    /// `--pane`. Polls for mount + realization like `typeQuick`; fails fast with `quick terminal not open`
    /// when never shown, `failed to read surface buffer` if a shown surface never realizes, `no open window`.
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
