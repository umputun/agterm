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

    /// LinkDisposition is the action for a clicked link.
    public enum LinkDisposition: Equatable {
        case open(URL)
        case reveal(URL)
        /// image is a local file with a `imageExtensions` extension, shown as a picture instead of revealed.
        case image(URL)
        /// markdown is a local file with a `markdownExtensions` extension, rendered instead of revealed.
        case markdown(URL)
        /// text is a local file `TextPage` accepts, shown read-only at `line` instead of revealed.
        case text(URL, line: Int?)
        /// document is a local file with a `DocumentPage.extensions` extension, shown as an unprivileged page.
        case document(URL)
        case ignore
    }

    /// LinkLocation is a local file a clicked link may name, with the line a `:line[:column]` suffix gave.
    public struct LinkLocation: Equatable, Sendable {
        public let path: String
        public let line: Int?

        public init(path: String, line: Int? = nil) {
            self.path = path
            self.line = line
        }
    }

    /// TextLink is a text page a click opens: the file, the line to mark, the owning session and the panel
    /// size, nil for full size.
    public struct TextLink: Equatable, Sendable {
        public let url: URL
        public let line: Int?
        public let session: UUID
        public let sizePercent: Int?

        public init(url: URL, line: Int?, session: UUID, sizePercent: Int?) {
            self.url = url
            self.line = line
            self.session = session
            self.sizePercent = sizePercent
        }
        /// opensAsLog says whether the click opens a log page following the file: a plain click on a `.log` or `.out`
        /// file, never a `path:line` location, which keeps the static page at that line.
        public var opensAsLog: Bool { line == nil && TextPage.isLog(file: url.path) }
    }

    /// The extensions a clicked local path shows as a picture. SVG is left out: it is a document that can
    /// carry script, not a bitmap.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// markdownExtensions lists the local file extensions rendered as Markdown.
    public static let markdownExtensions: Set<String> = ["md", "markdown"]

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
        /// markdown renders a local markdown file over `session` at `sizePercent`, nil for full size; a refused
        /// open reveals it instead.
        case markdown(URL, session: UUID, sizePercent: Int?)
        /// text shows a local text file over its session; a refused open reveals it instead.
        case text(TextLink)
        /// document shows a local HTML file over `session` at `sizePercent`, nil for full size; a refused open reveals
        /// it instead.
        case document(URL, session: UUID, sizePercent: Int?)
        case reveal(URL)
        case ignore

        /// localFile is the file a local route names, which a reveal chord selects in Finder instead; nil for a
        /// web route and for an ignored link.
        public var localFile: URL? {
            switch self {
            case .image(let url, _), .markdown(let url, _, _), .document(let url, _, _), .reveal(let url): return url
            case .text(let link): return link.url
            case .browser, .overlay, .ignore: return nil
            }
        }
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

    /// disposition maps a raw terminal link to an action: a permitted web/mail scheme → `.open`; a local path → `.image`,
    /// `.markdown`, `.document`, `.text` or `.reveal` (`localPath`); a `file://` with a non-local host, or any other scheme, schemeless or
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

    /// localPath classifies a decoded local path: `.image` for an `imageExtensions` file, `.markdown` for a
    /// `markdownExtensions` one, `.document` for a `DocumentPage.extensions` one, `.text` for a `TextPage`-eligible one, `.reveal` for anything else, and `.ignore` for an empty or relative path (which `URL(fileURLWithPath:)` would
    /// resolve against the process directory), a UNC-style `//` path (a remote target the host check cannot
    /// see), or an auto-mount path. The automount check runs after LEXICAL `..` collapsing, so
    /// `/tmp/../net/x` cannot sneak through and the classifier never stats the path it is about to deny.
    /// It never resolves symlinks either: do NOT swap in `standardizedFileURL`/`resolvingSymlinksInPath()`,
    /// which touch the filesystem.
    static func localPath(_ path: String, line: Int? = nil) -> LinkDisposition {
        guard let normalized = guardedLocalPath(path) else { return .ignore }
        let url = URL(fileURLWithPath: normalized, isDirectory: false)
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image(url) }
        if markdownExtensions.contains(ext) { return .markdown(url) }
        if DocumentPage.extensions.contains(ext) { return .document(url) }
        return TextPage.isEligible(file: normalized) ? .text(url, line: line) : .reveal(url)
    }

    /// guardedLocalPath is `path` lexically normalized, nil for a relative, UNC-style or auto-mount path, or one
    /// holding a control character: a decoded `%00` would make `open()` read the name before it.
    static func guardedLocalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let normalized = lexicallyNormalizedAbsolutePath(path)
        return isAutomountPath(normalized) ? nil : normalized
    }

    /// locations lists the files a link may name when only the filesystem can tell which: one ending in
    /// `:line[:column]` or in sentence punctuation (`trimmedSpellings`), the literal path first so a file named
    /// with a colon or a dot still wins, or a relative one joined to the pane's `cwd` before any scheme parse. Empty when `route(for:)` decides the link as typed.
    /// Every candidate passed `guardedLocalPath`, so a refused path is never stat'ed; a remote pane's paths
    /// name files on another Mac and offer none.
    public static func locations(for raw: String, origin: ClickOrigin, cwd: String?,
                                 localHosts: Set<String> = localHostNames, home: String = NSHomeDirectory()) -> [LinkLocation] {
        if case .remotePane = origin { return [] }
        guard !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return [] }
        var relative = false
        let path: String
        if isBarePath(raw) {
            path = raw.hasPrefix("~/") ? home + raw.dropFirst() : raw
        } else if let joined = relativePath(raw, cwd: cwd) {
            (path, relative) = (joined, true)
        } else if let url = URL(string: raw), url.scheme?.lowercased() == "file",
                  case let host = normalizedHost(url.host(percentEncoded: false) ?? ""), host.isEmpty || localHosts.contains(host) {
            path = url.path(percentEncoded: false)
        } else {
            return []
        }
        guard let literal = guardedLocalPath(path) else { return [] }
        let spellings = [literal] + trimmedSpellings(path).compactMap(guardedLocalPath)
        var found: [LinkLocation] = []
        for spelling in spellings {
            let suffix = lineSuffix(spelling)
            if relative || suffix != nil || spellings.count > 1 { found.append(LinkLocation(path: spelling)) }
            if let suffix, let stripped = guardedLocalPath(suffix.path) { found.append(LinkLocation(path: stripped, line: suffix.line)) }
        }
        return found
    }

    /// trailingPunctuation ends a sentence after a printed path; libghostty's path rule keeps it in the link.
    /// A comma or a closing bracket already ends the link, and a detected one never ends in a colon.
    static let trailingPunctuation: Set<Character> = [".", "?", "!", ";"]

    /// trimmedSpellings lists `path` with up to three trailing `trailingPunctuation` characters removed, one at
    /// a time and longest first, so a name really ending in one still wins. It stops before leaving a last
    /// component of punctuation alone, so `/x/..` never becomes `/x/.`. The cap bounds what a click on a long
    /// run builds and stats.
    static func trimmedSpellings(_ path: String) -> [String] {
        var out: [String] = []
        var rest = Substring(path)
        while out.count < 3, let last = rest.last, trailingPunctuation.contains(last) {
            rest = rest.dropLast()
            let name = rest.reversed().prefix { $0 != "/" }
            guard name.contains(where: { !trailingPunctuation.contains($0) }) else { break }
            out.append(String(rest))
        }
        return out
    }

    /// relativePath joins a relative link to an absolute, control-free `cwd`. A first segment with a colon
    /// is a scheme or a host and port, never a directory, so `http://localhost:3000` stays a web link.
    static func relativePath(_ raw: String, cwd: String?) -> String? {
        guard let cwd, cwd.hasPrefix("/"), !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let slash = raw.firstIndex(of: "/") else { return nil }
        let first = raw[..<slash]
        guard !first.isEmpty, !first.contains(":"), !first.hasPrefix("~") else { return nil }
        return cwd + "/" + raw
    }

    /// lineSuffix splits a trailing `:line` or `:line:column` off `path`, nil unless the line is 1 or more and a
    /// file name remains. The column is dropped: a text page scrolls to the line.
    static func lineSuffix(_ path: String) -> (path: String, line: Int)? {
        var parts = path.split(separator: ":", omittingEmptySubsequences: false)
        let number = { (part: Substring) -> Int? in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
        }
        guard parts.count >= 2, let last = number(parts[parts.count - 1]) else { return nil }
        var line = last
        if parts.count >= 3, let before = number(parts[parts.count - 2]) {
            line = before
            parts.removeLast()
        }
        parts.removeLast()
        let base = parts.joined(separator: ":")
        guard line >= 1, !base.isEmpty, !base.hasSuffix("/") else { return nil }
        return (base, line)
    }

    /// ClickIntent is what a link click's chord asks for: the setting's route, the browser, or a Finder reveal.
    public enum ClickIntent: Equatable, Sendable {
        case normal, browser, reveal
    }

    /// clickIntent reads a link click's chord. ⌘⇧ asks for the browser over an overlay setting, except under
    /// mouse capture, where ⌘⇧ is the only link click and so follows the setting. ⌘⌥ reveals a local path in
    /// Finder from any origin; under capture, where Shift is the bypass, ⌘⌥⇧ does.
    public static func clickIntent(modifiers: KeyModifiers, mode: LinkOpenMode, origin: ClickOrigin,
                                   mouseCaptured: Bool) -> ClickIntent {
        if modifiers == (mouseCaptured ? [.command, .option, .shift] : [.command, .option]) { return .reveal }
        guard modifiers == [.command, .shift], mode != .browser, !mouseCaptured else { return .normal }
        switch origin {
        case .pane, .remotePane, .scratch: return .browser
        case .hud, .programOverlay, .quick: return .normal
        }
    }

    /// wantsBrowser reports whether a ⌘⇧ link click overrides the overlay setting and goes to the browser.
    public static func wantsBrowser(modifiers: KeyModifiers, mode: LinkOpenMode, origin: ClickOrigin,
                                    mouseCaptured: Bool) -> Bool {
        clickIntent(modifiers: modifiers, mode: mode, origin: origin, mouseCaptured: mouseCaptured) == .browser
    }

    /// Maps a raw link to its route: `disposition` decides first. A web link the overlay can show
    /// (`overlayCanShow`), clicked in a pane or the scratch terminal, goes to that session's overlay at the
    /// mode's size when `mode` is an overlay one; an image from there shows over the session in every mode, and a
    /// markdown or HTML file renders there at the mode's size, 95% in browser mode, since a browser would get the raw file.
    /// A remote pane ignores bare paths and reveals `file://` pictures, markdown, HTML and text files, since all name files
    /// on another Mac.
    /// Whether the overlay is free right now is the caller's check.
    public static func route(for raw: String, mode: LinkOpenMode, origin: ClickOrigin,
                             localHosts: Set<String> = localHostNames, home: String = NSHomeDirectory()) -> Route {
        if case .remotePane = origin, isBarePath(raw) { return .ignore }
        return route(disposition(for: raw, localHosts: localHosts, home: home), mode: mode, origin: origin)
    }

    /// Maps a location `locations` offered, and the caller found on disk, to its route by the same origin rules.
    public static func route(for location: LinkLocation, mode: LinkOpenMode, origin: ClickOrigin) -> Route {
        route(localPath(location.path, line: location.line), mode: mode, origin: origin)
    }

    private static func route(_ disposition: LinkDisposition, mode: LinkOpenMode, origin: ClickOrigin) -> Route {
        let pageSize = mode == .browser ? 95 : mode.overlaySizePercent
        switch disposition {
        case .ignore: return .ignore
        case .reveal(let url): return .reveal(url)
        case .image(let url):
            switch origin {
            case .pane(let session), .scratch(let session): return .image(url, session: session)
            case .remotePane, .hud, .programOverlay, .quick: return .reveal(url)
            }
        case .markdown(let url):
            switch origin {
            case .pane(let session), .scratch(let session):
                return .markdown(url, session: session, sizePercent: pageSize)
            case .remotePane, .hud, .programOverlay, .quick: return .reveal(url)
            }
        case .document(let url):
            switch origin {
            case .pane(let session), .scratch(let session):
                return .document(url, session: session, sizePercent: pageSize)
            case .remotePane, .hud, .programOverlay, .quick: return .reveal(url)
            }
        case .text(let url, let line):
            switch origin {
            case .pane(let session), .scratch(let session):
                return .text(TextLink(url: url, line: line, session: session, sizePercent: pageSize))
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
