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
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }   // trim at NUL, then decode
            raw.insert(String(decoding: bytes, as: UTF8.self))
        }
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
            if norm.hasSuffix(".local") {
                let short = String(norm.dropLast(6))                               // add the short form too,
                if !short.isEmpty { out.insert(short) }                            // but a bare ".local" → "" is skipped
            }
        }
        return out
    }

    /// Lowercase a host and drop a trailing FQDN dot so matching is stable.
    static func normalizedHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }

    /// The macOS auto-mount roots where a Finder reveal can trigger an NFS/SMB automount: `/net` (`-hosts`),
    /// `/Network` (`/Network/Servers`), and `/home` (`auto_home`), PLUS their canonical Data-volume paths
    /// under `/System/Volumes/Data/…`. On modern macOS `/home` is a firmlink/symlink and `auto_home` is
    /// actually mounted at `/System/Volumes/Data/home`, so a LITERAL `/System/Volumes/Data/home/<user>` link
    /// would otherwise slip past the `/home` entry and still trip the mount. Matched against the EXACT root or
    /// a `<root>/…` child, case-insensitively (the boot volume is case-insensitive, so `/NET/…` mounts too),
    /// so a sibling like `/networkx` is NOT caught; the broad Data root `/System/Volumes/Data` itself is
    /// deliberately NOT listed (it backs every real file, e.g. `/System/Volumes/Data/Users/…`). The path must
    /// already be dot-normalized (see `disposition`).
    static func isAutomountPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["/net", "/network", "/home",
                "/system/volumes/data/home",
                "/system/volumes/data/net",
                "/system/volumes/data/network/servers"].contains { lower == $0 || lower.hasPrefix($0 + "/") }
    }

    /// Collapse `.`/`..` segments in an ABSOLUTE path with a purely LEXICAL, string-only normalizer — no
    /// filesystem access (unlike `URL.standardizedFileURL`, which stats the target) and no symlink resolution,
    /// so the classifier never touches the very automount path it may be about to deny (a `stat` of a path
    /// inside autofs could itself trigger the mount). A leading `..` at the root is dropped. The caller
    /// guarantees an absolute input (`hasPrefix("/")`).
    static func lexicallyNormalizedAbsolutePath(_ path: String) -> String {
        var out: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(comp)
        }
        return "/" + out.joined(separator: "/")
    }

    /// Maps a raw terminal link to an action: a permitted web/mail scheme → `.open`; a LOCAL `file://` link
    /// (empty host, or a host in `localHosts`) → `.reveal` of the HOST-STRIPPED, dot-normalized local path, so
    /// Finder only ever sees a plain `/…` path and never leans on the original authority for host handling; a
    /// `file://` with a non-local host, an empty/relative path, a UNC-style `//`-path, an auto-mount path
    /// (`/net`, `/Network`, `/home` — checked AFTER `..` normalization so `/tmp/../net/x` can't sneak
    /// through), or any other scheme / schemeless / unparseable input → `.ignore`. `localHosts` is injected
    /// (default: this machine's names) so the decision stays host-free and unit-testable.
    public static func disposition(for raw: String, localHosts: Set<String> = localHostNames) -> LinkDisposition {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return .ignore }
        if permittedSchemes.contains(scheme) { return .open(url) }
        guard scheme == "file" else { return .ignore }
        let host = normalizedHost(url.host(percentEncoded: false) ?? "")
        guard host.isEmpty || localHosts.contains(host) else { return .ignore }
        // reject an empty/relative path (an empty path would make `URL(fileURLWithPath:)` the process CWD) and
        // a UNC-style `//` path (a remote target hidden in the path where the host check can't see it).
        let rawPath = url.path(percentEncoded: false)
        guard rawPath.hasPrefix("/"), !rawPath.hasPrefix("//") else { return .ignore }
        // reveal a host-stripped local path, collapsing `.`/`..` with a purely LEXICAL normalizer (string
        // only) so `/tmp/../net/x` can't sneak past the automount check AND the classifier never stats — and
        // so never risks triggering — the automount path it is about to deny. It also never resolves symlinks:
        // a `/tmp/link -> /net` link reveals the link itself, never the target (do NOT swap in
        // `standardizedFileURL`/`resolvingSymlinksInPath()`, which touch the filesystem).
        let normalizedPath = Self.lexicallyNormalizedAbsolutePath(rawPath)
        guard !isAutomountPath(normalizedPath) else { return .ignore }
        return .reveal(URL(fileURLWithPath: normalizedPath, isDirectory: false))
    }
}
