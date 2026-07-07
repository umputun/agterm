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
            // a default whose key can't round-trip through the keymap grammar (e.g. increase_font_size's
            // `+`, which clashes with the `+` separator) is documented as not file-expressible rather
            // than printed as an unparseable token like `cmd++`.
            let chord = action.defaultChord.map(starterChordSyntax) ?? "(no default)"
            return "#   \(action.rawValue.padding(toLength: nameColumnWidth, withPad: " ", startingAt: 0))\(chord)"
        }.joined(separator: "\n")
        let tokenLines = CommandContext.tokenNames.map { "#   {\($0)}" }.joined(separator: "\n")

        return """
        # agterm keymap — a kitty-flavored config for rebinding built-in shortcuts and defining
        # custom shell commands. Edit this file and run File ▸ Reload Keymap (or `agtermctl keymap
        # reload`) to apply. Blank lines and lines starting with `#` are ignored.
        #
        # Two verbs:
        #
        #   map <chord> <action>
        #       Rebind a built-in action to a single chord (no leader sequences for built-ins).
        #       Chords use kitty syntax: mods joined by `+`, e.g. `cmd+shift+d`, `ctrl+\\``.
        #       Mods: ctrl, cmd, opt, shift. A Shift-typed symbol is shift+<base key>
        #       (shift+/ for ?, shift+= for +, shift+5 for %). Example:
        #
        #           map cmd+shift+d  toggle_split
        #
        #   command "<name>" [chord] <shell...>
        #       Define a custom command, shown in the action palette marked `custom`. The quoted
        #       name may contain spaces. An optional chord (single chord OR a leader like `ctrl+a>g`)
        #       binds it to a key; the chord MUST include a modifier (a bare key is rejected and the
        #       line becomes palette-only). Omit the chord for a palette-only command. The rest of the
        #       line is run via `/bin/sh -c`, detached with no terminal — so it suits fire-and-forget
        #       launches (GUI apps, scripts), NOT a bare interactive or full-screen TUI program, which
        #       has no TTY and exits at once. Launch a TUI over a session through an overlay terminal,
        #       as the Lazygit example does. Examples:
        #
        #           command "Open in Zed"  cmd+shift+e  open -a Zed "$AGT_SESSION_PWD"
        #           command "Lazygit"      ctrl+a>g     agtermctl session overlay open lazygit --socket "$AGT_SOCKET"
        #           command "Deploy"                    ./deploy.sh
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
        # map cmd+shift+d toggle_split

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

    /// The shell command that opens `path` in the user's editor (`$VISUAL` else `$EDITOR` else `vi`),
    /// working under POSIX login shells (zsh/bash/dash) AND fish. Shared by the keymap and ghostty-config
    /// editor overlays.
    ///
    /// The user's INTERACTIVE login shell (`$SHELL -ilc`) is run first so it sources its rc and EXPORTS
    /// `$EDITOR`/`$VISUAL` — the overlay's own process is a bare non-interactive `/bin/sh` that sources
    /// none of the user's shell config, and a GUI-launched app inherits no shell env, so without this the
    /// editor resolution always fell back to `vi`. The login shell then `exec`s a POSIX `/bin/sh` that does
    /// the actual `${VISUAL:-${EDITOR:-vi}} "$1"` resolution + launch. Doing the resolution in the inner
    /// `/bin/sh` (not in `$SHELL` directly) is what makes this work for fish: it can't parse POSIX
    /// `${VAR:-default}` parameter-expansion, so the previous `$SHELL -ilc '${VISUAL:-${EDITOR:-vi}} …'`
    /// died with `${ is not a valid variable` (exit 127) and the overlay just flashed. Here that POSIX text
    /// rides inside single quotes that fish (and POSIX shells) pass through verbatim to the inner `/bin/sh`.
    /// The path is embedded single-quoted as the inner `/bin/sh`'s positional `$1` (NOT passed positionally
    /// to `$SHELL`, since fish has no `$1`), so spaces and embedded quotes survive.
    ///
    /// Two known limits: it assumes `$SHELL` accepts the `-ilc` flags and passes single-quoted text
    /// verbatim — true for sh/bash/zsh/fish, NOT csh/tcsh (which reject `-ilc`); and it resolves
    /// `$EDITOR`/`$VISUAL` only when EXPORTED (their universal convention — `export EDITOR=…` /
    /// fish `set -gx EDITOR …`), since a non-exported, shell-local value does not survive the `exec`.
    public static func editorCommand(forPath path: String) -> String {
        // POSIX single-quote: wrap in '…' and escape any embedded ' as '\'' (works in fish + POSIX shells).
        func singleQuoted(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }
        // the POSIX resolution + launch, run by the inner /bin/sh regardless of the login shell.
        let inner = "${VISUAL:-${EDITOR:-vi}} \"$1\""
        // what the login shell runs: source its rc (above), then hand off to /bin/sh with the path as $1.
        let viaPosix = "exec /bin/sh -c \(singleQuoted(inner)) agterm-config-edit \(singleQuoted(path))"
        return "${SHELL:-/bin/zsh} -ilc \(singleQuoted(viaPosix))"
    }
}
