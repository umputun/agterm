import Foundation

/// Pure resolvers for the user-editable config directory and the keymap file path, mirroring
/// `ControlResolve`'s shape (an enum of static resolvers) so the app and any host-free caller agree
/// on where the keymap lives.
public enum ConfigPaths {
    /// Resolve the config directory holding `keymap.conf`. Precedence:
    /// - explicit `setting` (the `AppSettings.configDirectory` value, when non-nil/non-empty) wins.
    /// - else `<stateDir>/config` when `stateDir` (the `AGTERM_STATE_DIR` value) is set — test isolation.
    /// - else `<home>/.config/agterm`.
    public static func configDirectory(setting: String?, stateDir: String?, home: URL) -> URL {
        if let setting, !setting.isEmpty { return URL(fileURLWithPath: setting) }
        if let stateDir, !stateDir.isEmpty {
            return URL(fileURLWithPath: stateDir).appendingPathComponent("config")
        }
        return home.appendingPathComponent(".config").appendingPathComponent("agterm")
    }

    /// The keymap file path within a resolved config directory: `<dir>/keymap.conf`.
    public static func keymapPath(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("keymap.conf")
    }

    /// The commented starter `keymap.conf`: the two-verb syntax, every `BuiltinAction` raw name with
    /// its shipped default chord (or "no default"), and the `{AGT_X}` token list. Every line is a
    /// comment so a fresh file rebinds nothing.
    public static func starterKeymapConf() -> String {
        // pad the action name column to the longest raw name (+ a 2-space gutter) so a future action
        // longer than any current one can never silently truncate.
        let nameColumnWidth = (BuiltinAction.allCases.map { $0.rawValue.count }.max() ?? 0) + 2
        let actionLines = BuiltinAction.allCases.map { action -> String in
            // a default whose key can't round-trip through the keymap grammar (increase_font_size's `+`
            // clashes with the `+` separator) documents as not-expressible, not an unparseable `cmd++`.
            let chord = action.defaultChord.map(starterChordSyntax) ?? "(no default)"
            return "#   \(action.rawValue.padding(toLength: nameColumnWidth, withPad: " ", startingAt: 0))\(chord)"
        }.joined(separator: "\n")
        let tokenLines = CommandContext.tokenNames.map { "#   {\($0)}" }.joined(separator: "\n")

        return """
        # agterm keymap — a kitty-flavored config for rebinding built-in shortcuts and defining
        # custom shell commands. Edit this file and run File ▸ Reload Keymap (or `agtermctl keymap
        # reload`) to apply. Blank lines and lines starting with `#` are ignored. A line that is
        # rejected or skipped is reported in Settings ▸ Key Mapping and by `agtermctl keymap list`.
        #
        # Three verbs:
        #
        #   map <chord> <action>
        #       Rebind a built-in action. Chords use kitty syntax: mods joined by `+`, e.g.
        #       `cmd+shift+l`, `ctrl+\\``. Mods: ctrl, cmd, opt, shift. A Shift-typed symbol is
        #       shift+<base key> (shift+/ for ?, shift+= for +, shift+5 for %). Several
        #       alternatives may be joined by `|` with no spaces around it; the first single-chord
        #       alternative becomes the menu shortcut and the rest fire through a key monitor, so
        #       they need a modifier on their first chord. A line offering no single chord leaves
        #       the action with no menu shortcut at all. Examples:
        #
        #           map cmd+shift+l     toggle_split
        #           map cmd+t|ctrl+a>t  toggle_scratch
        #
        #   command "<name>" [chord] <shell...>
        #       Define a custom command, shown in the action palette marked `custom`. The quoted
        #       name may contain spaces. An optional chord (single chord OR a leader like `ctrl+a>g`,
        #       or several of either joined by `|`) binds it to a key; every alternative MUST include
        #       a modifier on its first chord — one that does not is dropped, and a line left with
        #       none becomes palette-only. Omit the chord for a palette-only command. The rest of the
        #       line is run via `/bin/sh -c`, detached with no terminal — so it suits fire-and-forget
        #       launches (GUI apps, scripts), NOT a bare interactive or full-screen TUI program, which
        #       has no TTY and exits at once. Launch a TUI over a session through an overlay terminal,
        #       as the Lazygit example does. The line resolves binaries against the app's GUI `PATH`:
        #       the launchd default plus the bundled agtermctl, /usr/local/bin and /opt/homebrew/bin.
        #       A bare agtermctl or Homebrew binary works; anything else your shell profile adds does
        #       not, so give it an absolute path or wrap the line in `zsh -lc '...'` — `zsh -ilc '...'`
        #       when that PATH comes from ~/.zshrc, which -lc does not read. The program an overlay or
        #       scratch terminal runs gets the app's own unwidened PATH and always needs one of those.
        #       Examples:
        #
        #           command "Open in Zed"  cmd+shift+e  open -a Zed "$AGT_SESSION_PWD"
        #           command "Lazygit"      ctrl+a>g     agtermctl session overlay open 'zsh -lc lazygit' --socket "$AGT_SOCKET"
        #           command "Deploy"                    ./deploy.sh
        #
        #   global-hotkey <chord>
        #       Bind ONE system-wide chord that summons the quick terminal while any application is
        #       frontmost — the only binding here that fires when agterm does not have the keyboard.
        #       Exactly one chord: no `|` alternatives, no leader sequence, and it must carry a
        #       modifier. A second global-hotkey line replaces the first. macOS registers it by
        #       physical key position, so it keeps working on a non-Latin layout. Because the system
        #       owns it rather than agterm, it takes no part in the collision rules above. Note the
        #       precedence: the system hotkey WINS, agterm frontmost included, so a chord shared with a
        #       menu action fires this and the menu binding never sees it. There is no default because
        #       registering a chord takes it from every other application on your Mac, which is not a
        #       cost to impose on someone who never summons the panel from outside agterm. Spending it
        #       on the chord the in-app binding already uses is allowed, and is how to get ONE shortcut
        #       that works everywhere — at the price of that chord no longer reaching anything else.
        #       Examples:
        #
        #           global-hotkey ctrl+opt+space
        #           global-hotkey ctrl+`            # same chord as the in-app quick_terminal binding
        #
        # Built-in actions (raw name → shipped default chord):
        #
        \(actionLines)
        #
        # Custom-command tokens (expanded in the shell line and exported as $AGT_X env vars):
        #
        \(tokenLines)
        #
        # NOTE: a {AGT_X} token is substituted RAW into the /bin/sh line — convenient, but unsafe for
        # content you don't control. {AGT_SELECTION} is the obvious case, but a remote host can also set
        # the session title (OSC) and the working directory (OSC 7), so {AGT_SESSION_NAME} and
        # {AGT_SESSION_PWD} are equally unsafe raw. For any such content prefer the matching $AGT_X
        # environment variable, QUOTED, e.g. "$AGT_SELECTION".
        #
        # Uncomment and edit a line below to start.
        # map cmd+shift+l toggle_split
        # global-hotkey ctrl+opt+space

        """
    }

    private static func starterChordSyntax(_ chord: Chord) -> String {
        let rendered = chord.displayString
        guard parseKeybind(rendered) == [chord] else { return "(not expressible)" }
        return rendered
    }

    /// The agterm-scoped ghostty config file path within a resolved config directory: `<dir>/ghostty.conf`.
    /// Co-located with `keymap.conf` so a user-set custom config dir holds both.
    public static func ghosttyConfigPath(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("ghostty.conf")
    }

    /// The restore-running-command denylist file within a resolved config directory:
    /// `<dir>/restore-denylist.conf`. Co-located with `keymap.conf`/`ghostty.conf`.
    public static func restoreDenylistPath(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("restore-denylist.conf")
    }

    /// The shell command that opens `path` in the user's editor (`$VISUAL` else `$EDITOR` else `vi`), under
    /// POSIX login shells (zsh/bash/dash) AND fish. Shared by the keymap and ghostty-config editor overlays.
    ///
    /// The user's INTERACTIVE login shell (`$SHELL -ilc`) runs first so it sources its rc and EXPORTS
    /// `$EDITOR`/`$VISUAL`: the overlay's own process is a bare non-interactive `/bin/sh` sourcing none of
    /// the user's shell config, and a GUI-launched app inherits no shell env, so without this the editor
    /// resolution always fell back to `vi`. It then `exec`s a POSIX `/bin/sh` doing the actual
    /// `${VISUAL:-${EDITOR:-vi}} "$1"` resolution + launch — resolving there rather than in `$SHELL` is what
    /// makes fish work, since fish cannot parse POSIX `${VAR:-default}` and the previous
    /// `$SHELL -ilc '${VISUAL:-${EDITOR:-vi}} …'` died with `${ is not a valid variable` (exit 127), leaving
    /// the overlay to flash. That POSIX text rides in single quotes fish and POSIX shells pass through
    /// verbatim, and the path is embedded single-quoted as the inner shell's positional `$1` (NOT passed
    /// positionally to `$SHELL`, since fish has no `$1`), so spaces and embedded quotes survive.
    ///
    /// Two known limits: `$SHELL` must accept `-ilc` and pass single-quoted text verbatim — true for
    /// sh/bash/zsh/fish, NOT csh/tcsh, which reject `-ilc`; and `$EDITOR`/`$VISUAL` resolve only when
    /// EXPORTED (their universal convention — `export EDITOR=…` / fish `set -gx EDITOR …`), since a
    /// non-exported, shell-local value does not survive the `exec`.
    public static func editorCommand(forPath path: String) -> String {
        // POSIX single-quote: wrap in '…' and escape any embedded ' as '\'' (works in fish + POSIX shells).
        func singleQuoted(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }
        let inner = "${VISUAL:-${EDITOR:-vi}} \"$1\""
        let viaPosix = "exec /bin/sh -c \(singleQuoted(inner)) agterm-config-edit \(singleQuoted(path))"
        return "${SHELL:-/bin/zsh} -ilc \(singleQuoted(viaPosix))"
    }
}
