import Foundation

/// ShellEscape backslash-escapes a filesystem path (or URL) for insertion into a terminal as literal text —
/// the drag-drop / paste case: a dropped path with spaces or parentheses lands as ONE shell argument, while
/// a path with no shell-significant characters comes back UNCHANGED and unquoted, keeping the common case
/// clean for a CLI agent reading the path out of its prompt. Unlike `CommandRestore.shellQuote`, which
/// always single-quote-wraps an argv element for shell re-execution — right for re-running a captured
/// command, wrong here, since it would quote even a clean `/path/image.png`.
public enum ShellEscape {
    /// The shell-significant characters that get a backslash prefix. Backslash is FIRST so its own pass
    /// doesn't double-escape the backslashes added for the rest. `\n`/`\r` are escaped so a dropped filename
    /// with a newline can't inject a command via `inject(text:)`, where a bare newline is a Return.
    private static let significant: [Character] = Array("\\ ()[]{}<>\"'`!#$&;|*?\t\n\r")

    /// Backslash-escape every shell-significant character in `path`; a path with none is returned unchanged.
    public static func path(_ path: String) -> String {
        var result = path
        for character in significant {
            result = result.replacingOccurrences(of: String(character), with: "\\" + String(character))
        }
        return result
    }
}
