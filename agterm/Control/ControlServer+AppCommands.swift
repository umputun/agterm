import AppKit
import Foundation
import agtermCore

/// `ControlServer` APP-GLOBAL action adapter arms — no session/workspace target, acting on a whole window or
/// the app: the `tree` projection, sidebar visibility/view-mode and expand/collapse, keymap + ghostty-config
/// reload, theme slots, the app-wide quick terminal. Split out of the session-, workspace- and surface-scoped
/// `ControlServer+SessionActions.swift` for the file size limit.
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
    /// toggle). Flips only on a differing state; unknown mode and no open window are errors.
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
    /// Idempotent, and a graceful no-op in flagged mode (no workspace rows); a closed or absent window errors.
    /// Drives the same `AppActions.expandAllWorkspaces(in:)` the View menu / palette drive.
    func expandSidebar(window: String?) -> ControlResponse {
        resolver.resolveOpenPlacementStore(window) { store in
            actions.expandAllWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }

    /// Collapse every workspace except the current one, which stays expanded and scrolled into view; same
    /// window selector and flagged-mode/idempotency/error behavior as `expandSidebar`.
    func collapseSidebar(window: String?) -> ControlResponse {
        resolver.resolveOpenPlacementStore(window) { store in
            actions.collapseOtherWorkspaces(in: store)
            return ControlResponse(ok: true)
        }
    }

    /// Set a window's sidebar divider position in points, clamped to the drag bounds; `--window` picks the
    /// OPEN target, default frontmost. Echoes the STORED width, which is what tells a caller its
    /// out-of-range value was clamped, the request answering ok either way. Read back on the tree.
    func setSidebarWidth(_ points: Double, window: String?) -> ControlResponse {
        resolver.resolveOpenPlacementStore(window) { store in
            store.setSidebarWidth(points)
            return ControlResponse(ok: true, result: ControlResult(sidebarWidth: store.sidebarWidth))
        }
    }

    // MARK: - Keymap

    /// Re-read and re-parse `keymap.conf`, returning the parse-diagnostic count. The SAME `reloadKeymap()` path
    /// File ▸ Reload Keymap drives; only the reported count is control-native.
    func reloadKeymap() -> ControlResponse {
        settingsModel.reloadKeymap()
        return ControlResponse(ok: true, result: ControlResult(count: settingsModel.keymapDiagnostics.count))
    }

    /// The read side of `keymap.reload`: what the keymap resolved, plus what the menu bar is dispatching. The
    /// two can disagree — SwiftUI defers its menu rebuild to the next app activation, so a chord correct in the
    /// model can be stale in the menu. App-global, so no `--window` selector.
    func listKeymap() -> ControlResponse {
        let payload = ControlKeymap.project(keymap: settingsModel.keymap,
                                            diagnostics: settingsModel.keymapDiagnostics,
                                            path: settingsModel.keymapPath,
                                            menu: ControlServer.liveMenuKeyEquivalents())
        return ControlResponse(ok: true, result: ControlResult(keymap: payload))
    }

    /// Which app is serving this socket. App-global: no target, no `--window`, and no window needs to be
    /// open, which is what makes it usable as a preflight from a keymap-launched script — those inherit the
    /// app's launchd environment and so carry no `TERM_PROGRAM_VERSION`.
    func appIdentity() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(app: identity))
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
    /// reachable case, carrying whatever the user assigned in System Settings; top-level-only reporting would
    /// let a caller conclude nothing holds a chord when something does. `menu` stays the TOP-LEVEL title
    /// throughout, so a nested item is attributed to the menu-bar entry the reader can find it under. Internal
    /// rather than private so `CloseSessionChordTests`' companion can drive it over a hand-built nested menu:
    /// agterm's own submenus carry no key equivalents and Services entries depend on the user's system
    /// settings, so no real nested chord exists to assert against.
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
    /// order so the two render identically and compare as strings. Two AppKit spellings must be translated or
    /// the chord is uncomparable: arrows and return/tab/space/delete arrive as function-key or control
    /// CHARACTERS, rendering the key blank (`cmd+opt+` for the keymap's `cmd+opt+up`), so they go through
    /// `namedKey(forKeyEquivalent:)`; a shift-typed equivalent arrives as the SHIFTED character with `.shift`
    /// set (⇧E is `"E"`), so an ordinary key is lowercased to the grammar's base. The globe/fn modifier has no
    /// keymap spelling (the grammar knows ctrl/cmd/opt/shift only) but renders as `fn+` anyway — dropping it
    /// would print AppKit's ⌥⌘F-style items as bare unmodified keys, reading as a binding that does not exist;
    /// a `fn+` chord never matches an action's chord, which is correct.
    @MainActor
    private static func chordSyntax(for item: NSMenuItem) -> String {
        let mods = item.keyEquivalentModifierMask
        let key = item.keyEquivalent
        // an UPPERCASE key equivalent carries shift implicitly whatever the mask says: AppKit matches `"C"` +
        // [.command] against ⇧⌘C, not ⌘C. agterm's own items never spell it that way (`toShortcut` puts shift in
        // the mask), but this walk reports third-party items, where lowercasing would name an unfirable chord.
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

    /// Re-read and apply the ghostty config, returning the diagnostic count (0 = clean) across ALL sources —
    /// libghostty diagnostics carry no source-file attribution. Drives the SAME
    /// `AppActions.reloadGhosttyConfig()` File ▸ Reload Config drives (posting the warning banner); the count is
    /// what that reload produced, not a re-read. App-global (one settings model + one GhosttyApp), no `--window`.
    func reloadGhosttyConfig() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(count: actions.reloadGhosttyConfig()))
    }

    // MARK: - Theme

    /// Set + persist a theme PER SLOT — the control half of the Settings pickers / `.themes` palette commit (no
    /// live preview over the socket), app-global so no `--window`. `args.name` (alias `args.light`; both is an
    /// error) sets the light/single slot, keeping any dark one; `args.dark` sets the dark slot and turns
    /// macOS-appearance syncing ON (stored as ghostty's dual `light:,dark:`, light side seeded), and `none` (any
    /// case) clears it, syncing off. A nil/empty name picks ghostty's built-in colors ("default ghostty"), NOT
    /// the seeded `agterm` default; any other must be a bundled theme, else an error (a silent typo is worse).
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

    /// Show / hide / toggle the app's one quick terminal, flipping only when the state differs from
    /// `isVisible`. Unknown mode and no open window are errors — the panel is not window chrome, but it is
    /// still refused with no window open, agterm terminating on an empty open set.
    ///
    /// A window's terminal zoom is no longer a term: the panel floats above every window rather than being
    /// hosted by one, so a zoom layer can neither replace nor strand it.
    func setQuickTerminal(mode: String?) -> ControlResponse {
        let controller = QuickTerminalController.shared
        guard !library.openIDs().isEmpty else {
            return ControlResponse(ok: false, error: "no open window")
        }
        guard let parsedMode = ControlToggleMode.parse(mode, on: "show", off: "hide") else {
            return ControlResponse(ok: false, error: "invalid quick mode: \(mode ?? "toggle")")
        }
        let want = parsedMode.desiredValue(current: controller.isVisible)
        // NOT gated on the panel being hidden: `show` also carries the pin, and `canShow` refuses under a
        // pending pick, so an already-visible panel would answer ok with the pin silently not applied.
        if want, PickRegistry.shared.controller(for: library.activeWindowID)?.pending != nil {
            return ControlResponse(ok: false, error: "pick pending")
        }
        // `show` runs even when the panel is ALREADY visible, which `hide` has no equivalent of: it is what
        // pins a panel the user summoned by hotkey. Skipping it there would answer ok and leave the caller's
        // next command racing the blur the promise says it will not — see `show(dismissOnFocusLoss:)`.
        if want {
            controller.show(dismissOnFocusLoss: false)
        } else if controller.isVisible {
            controller.hide()
        }
        return ControlResponse(ok: true)
    }

    /// Inject `text` as literal keystrokes into the app's one quick terminal, the twin of
    /// `session.type`. `quick show` flips `isVisible` before SwiftUI mounts + libghostty realizes the surface,
    /// so this polls briefly rather than racing a back-to-back `quick show; quick type`. Fails fast with `quick
    /// terminal not open` when never shown (no surface AND not visible), else `quick terminal not realized`.
    func typeQuick(text: String) async -> ControlResponse {
        let controller = QuickTerminalController.shared
        guard !library.openIDs().isEmpty else {
            return ControlResponse(ok: false, error: "no open window")
        }
        // probe first, then sleep-then-probe up to 12 more times — a probe follows every sleep, so the full
        // ~360ms window is used (no wasted trailing sleep), matching `session.type`'s realize poll.
        for attempt in 0...12 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if let surface = controller.currentSurface() {
                // a false inject means the view exists but its surface isn't realized — keep polling rather than
                // report a silent-drop ok. a shown-then-hidden surface stays alive and typable, succeeding here.
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

    /// Read the quick-terminal screen as plain text, the twin of `session.text` and the
    /// read-back for `quick.type`. `all` adds scrollback, `lines` keeps the last N; one surface, so no `--pane`.
    /// Polls for mount + realization like `typeQuick`; a never-shown quick errors, an unrealized one gives
    /// `failed to read surface buffer`.
    func readQuickText(all: Bool, lines: Int?) async -> ControlResponse {
        let controller = QuickTerminalController.shared
        guard !library.openIDs().isEmpty else {
            return ControlResponse(ok: false, error: "no open window")
        }
        // same probe-then-sleep poll shape as `typeQuick`.
        for attempt in 0...12 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if let surface = controller.currentSurface() {
                // readScreenText returns nil only for an unrealized surface ("" for a realized blank screen),
                // so a non-nil result means the surface is up.
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
