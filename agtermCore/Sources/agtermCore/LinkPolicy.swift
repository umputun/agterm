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

    /// What a link click should do. Carries the target URL for `.open`/`.reveal`/`.image`.
    public enum LinkDisposition: Equatable {
        case open(URL)
        case reveal(URL)
        /// image is a local file with a `imageExtensions` extension, shown as a picture instead of revealed.
        case image(URL)
        case ignore
    }

    /// The extensions a clicked local path shows as a picture. SVG is left out: it is a document that can
    /// carry script, not a bitmap.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

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
        /// remotePane is a pane of a session attached from another Mac, whose printed paths name files there.
        case remotePane(UUID)
        case scratch(UUID)
        case hud
        case programOverlay
        case quick
    }

    /// What a link click should do once the link-open setting is applied. `browser` is the system opener,
    /// whatever handler the scheme maps to.
    public enum Route: Equatable, Sendable {
        case browser(URL)
        case overlay(URL, session: UUID, sizePercent: Int?)
        /// image shows a local picture over `session`, sized from the image; a refused open reveals it instead.
        case image(URL, session: UUID)
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

    /// Maps a raw terminal link to an action: a permitted web/mail scheme → `.open`; a local path → `.image`
    /// or `.reveal` (`localPath`); a `file://` with a non-local host, or any other scheme, schemeless or
    /// unparseable input → `.ignore`. A local path is a LOCAL `file://` link (empty host, or a host in
    /// `localHosts`), host-stripped so Finder never leans on the original authority, or a bare path
    /// (`isBarePath`) taken literally with `~/` expanded against `home`. Both are injected so the decision
    /// stays host-free and unit-testable.
    public static func disposition(for raw: String, localHosts: Set<String> = localHostNames,
                                   home: String = NSHomeDirectory()) -> LinkDisposition {
        if isBarePath(raw) {
            guard !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return .ignore }
            return localPath(raw.hasPrefix("~/") ? home + raw.dropFirst() : raw)
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return .ignore }
        if permittedSchemes.contains(scheme) { return .open(url) }
        guard scheme == "file" else { return .ignore }
        let host = normalizedHost(url.host(percentEncoded: false) ?? "")
        guard host.isEmpty || localHosts.contains(host) else { return .ignore }
        return localPath(url.path(percentEncoded: false))
    }

    /// isBarePath says whether `raw` is a path libghostty detected in plain output: never URL-parsed, so
    /// `%`, `#`, `?` and spaces stay part of the name. A relative one arrives resolved when it exists.
    static func isBarePath(_ raw: String) -> Bool {
        raw.hasPrefix("/") || raw.hasPrefix("~/")
    }

    /// localPath classifies a decoded local path: `.image` for an `imageExtensions` file, `.reveal` for
    /// anything else, and `.ignore` for an empty or relative path (which `URL(fileURLWithPath:)` would
    /// resolve against the process directory), a UNC-style `//` path (a remote target the host check cannot
    /// see), or an auto-mount path. The automount check runs after LEXICAL `..` collapsing, so
    /// `/tmp/../net/x` cannot sneak through and the classifier never stats the path it is about to deny.
    /// It never resolves symlinks either: do NOT swap in `standardizedFileURL`/`resolvingSymlinksInPath()`,
    /// which touch the filesystem.
    static func localPath(_ path: String) -> LinkDisposition {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return .ignore }
        let normalized = lexicallyNormalizedAbsolutePath(path)
        guard !isAutomountPath(normalized) else { return .ignore }
        let url = URL(fileURLWithPath: normalized, isDirectory: false)
        return imageExtensions.contains(url.pathExtension.lowercased()) ? .image(url) : .reveal(url)
    }

    /// wantsBrowser reports whether a ⌘⇧ link click overrides the overlay setting and goes to the browser.
    /// Under mouse capture ⌘⇧ is the only link click, so there it follows the setting.
    public static func wantsBrowser(modifiers: KeyModifiers, mode: LinkOpenMode, origin: ClickOrigin,
                                    mouseCaptured: Bool) -> Bool {
        guard modifiers == [.command, .shift], mode != .browser, !mouseCaptured else { return false }
        switch origin {
        case .pane, .remotePane, .scratch: return true
        case .hud, .programOverlay, .quick: return false
        }
    }

    /// Maps a raw link to its route: `disposition` decides first. A web link the overlay can show
    /// (`overlayCanShow`), clicked in a pane or the scratch terminal, goes to that session's overlay at the
    /// mode's size when `mode` is an overlay one; an image from there shows over the session in every mode.
    /// A remote pane ignores bare paths and reveals `file://` images, since both name files on another Mac.
    /// Whether the overlay is free right now is the caller's check.
    public static func route(for raw: String, mode: LinkOpenMode, origin: ClickOrigin,
                             localHosts: Set<String> = localHostNames, home: String = NSHomeDirectory()) -> Route {
        if case .remotePane = origin, isBarePath(raw) { return .ignore }
        switch disposition(for: raw, localHosts: localHosts, home: home) {
        case .ignore: return .ignore
        case .reveal(let url): return .reveal(url)
        case .image(let url):
            switch origin {
            case .pane(let session), .scratch(let session): return .image(url, session: session)
            case .remotePane, .hud, .programOverlay, .quick: return .reveal(url)
            }
        case .open(let url):
            guard mode != .browser, overlayCanShow(url) else { return .browser(url) }
            switch origin {
            case .pane(let session), .remotePane(let session), .scratch(let session):
                return .overlay(url, session: session, sizePercent: mode.overlaySizePercent)
            case .hud, .programOverlay, .quick: return .browser(url)
            }
        }
    }
}
