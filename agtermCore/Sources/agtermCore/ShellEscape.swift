import Foundation

/// ShellEscape backslash-escapes a filesystem path (or URL) for insertion into a terminal as literal text,
/// the drag-drop / paste path-insertion case: a dropped path with spaces or parentheses lands as ONE shell
/// argument, while a plain path with no shell-significant characters is returned UNCHANGED (no surrounding
/// quotes), keeping the common case clean for a CLI agent that reads the path out of its prompt.
///
/// This differs from `CommandRestore.shellQuote`, which always single-quote-wraps an argv element for shell
/// re-execution; that is the right choice for re-running a captured command, but wrong here because it would
/// wrap even a clean `/path/image.png` in quotes.
public enum ShellEscape {
    /// The shell-significant characters that get a backslash prefix. Backslash is FIRST so the pass that
    /// escapes it does not double-escape the backslashes added for the rest. `\n`/`\r` are escaped so a
    /// dropped filename with a newline can't inject a command via `inject(text:)` (bare newline → Return).
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
