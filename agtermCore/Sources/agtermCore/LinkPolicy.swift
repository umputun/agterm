import Foundation

/// Decides which link URLs agterm will open when a terminal hyperlink is clicked
/// (`GHOSTTY_ACTION_OPEN_URL`). A terminal renders UNTRUSTED program output, so an escape-sequence link
/// can carry any scheme — only web/mail links are followed. Notably `file://` is NOT allowed: opening one
/// goes through LaunchServices (the Finder double-click path), so a click on an attacker-controlled
/// `file:///…/X.app` or `.command` would LAUNCH it. Host-free (Foundation-only) so it is unit-tested; the
/// app-side glue just calls `NSWorkspace.open` on the result (same split as `ShellEscape`).
public enum LinkPolicy {
    /// The schemes safe to hand to the system opener — web + mail only, none that hands off to a local
    /// executable/handler.
    public static let permittedSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    /// The URL to open for a link click, or nil to ignore it: parseable AND carrying a permitted scheme
    /// (case-insensitive). nil for an unparseable string, a schemeless string, or a disallowed scheme
    /// (`file`, `javascript`, a custom app scheme, …).
    public static func permittedURL(from raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              permittedSchemes.contains(scheme) else { return nil }
        return url
    }
}
