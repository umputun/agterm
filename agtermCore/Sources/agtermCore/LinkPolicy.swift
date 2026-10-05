import Foundation

/// Decides what agterm does when a terminal hyperlink is clicked (`GHOSTTY_ACTION_OPEN_URL`). A terminal
/// renders UNTRUSTED program output, so an escape-sequence link can carry any scheme. `disposition(for:)`
/// maps a raw link to OPEN a web/mail URL (`NSWorkspace.open`), REVEAL a LOCAL `file://` link in Finder
/// (`NSWorkspace.activateFileViewerSelecting`), or IGNORE anything else. `file://` is revealed, never
/// opened: opening goes through LaunchServices (the Finder double-click path), so a click on
/// `file:///…/X.app` or `.command` would LAUNCH it, while reveal only selects it. A `file://` whose host is
/// NOT this machine is ignored, since `activateFileViewerSelecting` on a remote host can trigger a Finder
/// network/SMB mount. `route(for:mode:origin:)` adds the link-open setting on top: a web link clicked in a
/// pane or the scratch terminal may go to a session overlay instead of the browser. Host-free
/// (Foundation-only) so it is unit-tested — the local host names are injected; the app side only carries
/// out the route (same split as `ShellEscape`).
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

    /// Whether a web view of this app can load plain http from `host`. The app allows local networking
    /// only, and App Transport Security reads "local" off the host's SYNTAX, never off where it resolves:
    /// an unqualified name, a `.local` name, or an IP literal, a public one included.
    static func loadsPlainHTTP(host: String) -> Bool {
        let host = normalizedHost(host)
        guard !host.isEmpty else { return false }
        if host.hasSuffix(".local") || !host.contains(where: { $0 == "." || $0 == ":" }) { return true }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// Whether a session web overlay can show `url`: https, or plain http from a host `loadsPlainHTTP`
    /// accepts. `mailto`, `ftp` and other plain http go to the system handler.
    static func overlayCanShow(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return loadsPlainHTTP(host: url.host(percentEncoded: false) ?? "")
        default: return false
        }
    }

    /// Where a clicked link came from. Only a pane and the scratch terminal have an owning session a page
    /// could open on; a HUD link stays in the browser so the click never replaces the HUD it sits in.
    public enum ClickOrigin: Equatable, Sendable {
        case pane(UUID)
        case scratch(UUID)
        case hud
        case programOverlay
        case quick
    }

    /// What a link click should do once the link-open setting is applied. `browser` is the system opener,
    /// whatever handler the scheme maps to.
    public enum Route: Equatable, Sendable {
        case browser(URL)
        case overlay(URL, session: UUID)
        case reveal(URL)
        case ignore
    }

    /// Lowercased host names counting as "this machine" for a `file://` link: `localhost` and the
    /// `gethostname()` name (what GNU `ls --hyperlink` emits, e.g. `file://<host>/…`; `eza` uses an empty
    /// host, covered by the empty-host rule). Deliberately NOT `Host.current()`/`ProcessInfo.hostName`:
    /// those resolve via mDNS/Bonjour, tripping the macOS "find devices on local networks" prompt on first
    /// click, while `gethostname()` is a pure syscall. Computed ONCE, the default for `disposition`.
    public static let localHostNames: Set<String> = {
        var raw: Set<String> = ["localhost"]
        var buffer = [CChar](repeating: 0, count: 256)   // gethostname() — the name GNU ls uses, no network
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }   // trim at NUL, then decode
            raw.insert(String(decoding: bytes, as: UTF8.self))
        }
        return expandedHostNames(from: raw)
    }()

    /// Normalize each raw host name and add the `.local`-stripped short form beside the full one. Pure (no
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
    /// `/Network` (`/Network/Servers`), `/home` (`auto_home`), PLUS their canonical `/System/Volumes/Data/…`
    /// paths — `/home` is a firmlink/symlink and `auto_home` really lives at `/System/Volumes/Data/home`, so
    /// a LITERAL `/System/Volumes/Data/home/<user>` link would slip past the `/home` entry and still mount.
    /// Matched EXACT or as a `<root>/…` child, case-insensitively (the boot volume is case-insensitive, so
    /// `/NET/…` mounts too), so `/networkx` is NOT caught; the Data root `/System/Volumes/Data` is
    /// deliberately unlisted, backing every real file. The path must already be dot-normalized.
    static func isAutomountPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["/net", "/network", "/home",
                "/system/volumes/data/home",
                "/system/volumes/data/net",
                "/system/volumes/data/network/servers"].contains { lower == $0 || lower.hasPrefix($0 + "/") }
    }

    /// Collapse `.`/`..` in an ABSOLUTE path with a purely LEXICAL, string-only normalizer — no filesystem
    /// access (unlike `URL.standardizedFileURL`, which stats the target) and no symlink resolution, so the
    /// classifier never touches the automount path it may be about to deny (a `stat` inside autofs could
    /// itself trigger the mount). A leading `..` at the root is dropped; the caller guarantees an absolute
    /// input (`hasPrefix("/")`).
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
    /// (empty host, or a host in `localHosts`) → `.reveal` of the HOST-STRIPPED, dot-normalized local path,
    /// so Finder only ever sees a plain `/…` path and never leans on the original authority for host
    /// handling; a `file://` with a non-local host, an empty/relative path, a UNC-style `//`-path, an
    /// auto-mount path (`/net`, `/Network`, `/home`, checked AFTER `..` normalization so `/tmp/../net/x`
    /// can't sneak through), or any other scheme / schemeless / unparseable input → `.ignore`. `localHosts`
    /// is injected (default: this machine's names) so the decision stays host-free and unit-testable.
    public static func disposition(for raw: String, localHosts: Set<String> = localHostNames) -> LinkDisposition {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return .ignore }
        if permittedSchemes.contains(scheme) { return .open(url) }
        guard scheme == "file" else { return .ignore }
        let host = normalizedHost(url.host(percentEncoded: false) ?? "")
        guard host.isEmpty || localHosts.contains(host) else { return .ignore }
        // reject an empty/relative path (empty would make `URL(fileURLWithPath:)` the process CWD) and a
        // UNC-style `//` path (a remote target hidden where the host check can't see it).
        let rawPath = url.path(percentEncoded: false)
        guard rawPath.hasPrefix("/"), !rawPath.hasPrefix("//") else { return .ignore }
        // reveal a host-stripped local path, collapsing `.`/`..` LEXICALLY so `/tmp/../net/x` can't sneak
        // past the automount check and the classifier never stats — never risks triggering — the automount
        // path it is about to deny. It also never resolves symlinks: `/tmp/link -> /net` reveals the link,
        // not the target. Do NOT swap in `standardizedFileURL`/`resolvingSymlinksInPath()`, which touch the
        // filesystem.
        let normalizedPath = Self.lexicallyNormalizedAbsolutePath(rawPath)
        guard !isAutomountPath(normalizedPath) else { return .ignore }
        return .reveal(URL(fileURLWithPath: normalizedPath, isDirectory: false))
    }

    /// Maps a raw link to its route: `disposition` decides open, reveal or ignore, then a web link the
    /// overlay can show (`overlayCanShow`), clicked in a pane or the scratch terminal, goes to that session's
    /// overlay when `mode` is `overlay`. Whether the overlay is free right now is the caller's check.
    public static func route(for raw: String, mode: LinkOpenMode, origin: ClickOrigin,
                             localHosts: Set<String> = localHostNames) -> Route {
        switch disposition(for: raw, localHosts: localHosts) {
        case .ignore: return .ignore
        case .reveal(let url): return .reveal(url)
        case .open(let url):
            guard mode == .overlay, overlayCanShow(url) else { return .browser(url) }
            switch origin {
            case .pane(let session), .scratch(let session): return .overlay(url, session: session)
            case .hud, .programOverlay, .quick: return .browser(url)
            }
        }
    }
}
