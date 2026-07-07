import Foundation

/// Decides what agterm does when a terminal hyperlink is clicked (`GHOSTTY_ACTION_OPEN_URL`). A terminal
/// renders UNTRUSTED program output, so an escape-sequence link can carry any scheme. `disposition(for:)`
/// maps a raw link to one of three actions: OPEN a web/mail URL (`NSWorkspace.open`), REVEAL a LOCAL
/// `file://` link in Finder (`NSWorkspace.activateFileViewerSelecting`), or IGNORE anything else. `file://`
/// is revealed, never opened: opening it goes through LaunchServices (the Finder double-click path), so a
/// click on `file:///…/X.app` or `.command` would LAUNCH it — reveal only selects it, executing nothing. A
/// `file://` whose host is NOT this machine is ignored: `activateFileViewerSelecting` on a remote host can
/// trigger a Finder network/SMB mount. Host-free (Foundation-only) so it is unit-tested — the local host
/// names are injected into the decision; the app-side glue just calls the two `NSWorkspace` methods (same
/// split as `ShellEscape`).
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

    /// What a link click should do. Carries the target URL for `.open`/`.reveal`.
    public enum LinkDisposition: Equatable {
        case open(URL)
        case reveal(URL)
        case ignore
    }

    /// Lowercased host names that count as "this machine" for a `file://` link: `localhost` and the
    /// `gethostname()` name (what GNU `ls --hyperlink` emits, e.g. `file://<host>/…`; `eza` uses an empty
    /// host, covered separately by the empty-host rule). Deliberately does NOT consult `Host.current()` or
    /// `ProcessInfo.hostName`: those resolve names via mDNS/Bonjour, which trips the macOS "find devices on
    /// local networks" permission prompt on first click — `gethostname()` is a pure syscall that touches no
    /// network. Computed ONCE and used as the default for `disposition`.
    public static let localHostNames: Set<String> = {
        var raw: Set<String> = ["localhost"]
        var buffer = [CChar](repeating: 0, count: 256)   // gethostname() — the name GNU ls uses, no network
        if gethostname(&buffer, buffer.count) == 0 { raw.insert(String(cString: buffer)) }
        return expandedHostNames(from: raw)
    }()

    /// Normalize each raw host name and add the `.local`-stripped short form next to the full one. Pure (no
    /// syscalls), so the normalization + `.local` expansion feeding `localHostNames` stays unit-testable.
    static func expandedHostNames(from raw: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for name in raw {
            let norm = normalizedHost(name)
            guard !norm.isEmpty else { continue }
            out.insert(norm)
            if norm.hasSuffix(".local") { out.insert(String(norm.dropLast(6))) }   // add the short form too
        }
        return out
    }

    /// Lowercase a host and drop a trailing FQDN dot so matching is stable.
    static func normalizedHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }

    /// Maps a raw terminal link to an action: a permitted web/mail scheme → `.open`; a LOCAL `file://` link
    /// (empty host, or a host in `localHosts`) → `.reveal` (selected in Finder, never executed); a `file://`
    /// with a non-local host, a UNC-style `//`-path, or any other scheme / schemeless / unparseable input →
    /// `.ignore`. `localHosts` is injected (default: this machine's names) so the decision stays host-free
    /// and unit-testable.
    public static func disposition(for raw: String, localHosts: Set<String> = localHostNames) -> LinkDisposition {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return .ignore }
        if permittedSchemes.contains(scheme) { return .open(url) }
        guard scheme == "file" else { return .ignore }
        // A UNC-style path (`file:////server/share`, or `file://host//share`) hides a remote target in the
        // path where the host check can't see it — ignore so a stray link can't trip a Finder network mount.
        guard !url.path(percentEncoded: false).hasPrefix("//") else { return .ignore }
        let host = normalizedHost(url.host(percentEncoded: false) ?? "")
        return host.isEmpty || localHosts.contains(host) ? .reveal(url) : .ignore
    }
}
