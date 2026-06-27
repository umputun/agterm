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

    /// The agterm-scoped ghostty config file path within a resolved config directory: `<dir>/ghostty.conf`.
    /// Co-located with `keymap.conf` so a user-set custom config dir holds both.
    public static func ghosttyConfigPath(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("ghostty.conf")
    }

    /// The shell command that opens `path` in the user's editor (`$VISUAL` else `$EDITOR` else `vi`),
    /// working under ANY login shell — POSIX (zsh/bash) or not (fish, nushell). Shared by the keymap and
    /// ghostty-config editor overlays.
    ///
    /// The user's INTERACTIVE login shell (`$SHELL -ilc`) is run first so it sources its rc and EXPORTS
    /// `$EDITOR`/`$VISUAL` — the overlay's own process is a bare non-interactive `/bin/sh` that sources
    /// none of the user's shell config, and a GUI-launched app inherits no shell env, so without this the
    /// editor resolution always fell back to `vi`. The login shell then `exec`s a POSIX `/bin/sh` that does
    /// the actual `${VISUAL:-${EDITOR:-vi}} "$1"` resolution + launch. Doing the resolution in the inner
    /// `/bin/sh` (not in `$SHELL` directly) is what makes this work for non-POSIX shells: fish/nushell
    /// can't parse POSIX `${VAR:-default}` parameter-expansion, so the previous `$SHELL -ilc
    /// '${VISUAL:-${EDITOR:-vi}} …'` died with `${ is not a valid variable` (exit 127) and the overlay
    /// just flashed. Here that POSIX text rides inside single quotes that BOTH shell families pass through
    /// verbatim to the inner `/bin/sh`. The path is embedded single-quoted as the inner `/bin/sh`'s
    /// positional `$1` (NOT passed positionally to `$SHELL`, since fish has no `$1`), so spaces and
    /// embedded quotes survive. Caveat: this resolves `$EDITOR`/`$VISUAL` only when they are EXPORTED env
    /// vars — their entire purpose and the universal convention (`export EDITOR=…` / `set -gx EDITOR …`).
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
