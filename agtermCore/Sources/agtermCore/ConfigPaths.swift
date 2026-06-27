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

    /// The shell command that opens `path` in the user's editor (`$VISUAL` else `$EDITOR` else
    /// `vi`). It runs the editor through the user's INTERACTIVE login shell (`$SHELL -ilc`) so the editor
    /// resolves exactly as in a normal terminal — including an `$EDITOR`/`$VISUAL` set only in `~/.zshrc`.
    /// The overlay's own process is a bare non-interactive `/bin/sh` that sources NONE of the user's shell
    /// config (so a direct `${EDITOR:-vi}` there always fell back to `vi`); re-invoking `$SHELL -ilc` is
    /// what sources `.zshrc`/`.zprofile`/`.zshenv`. The path rides as a positional arg (`$1`):
    /// single-quoted at the eval level and double-quoted inside the `-c` script, so spaces and embedded
    /// quotes survive both layers without interpolating into the script. Shared by the keymap and
    /// ghostty-config editor overlays.
    public static func editorCommand(forPath path: String) -> String {
        let quoted = "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        return "${SHELL:-/bin/zsh} -ilc '${VISUAL:-${EDITOR:-vi}} \"$1\"' agterm-config-edit \(quoted)"
    }
}
