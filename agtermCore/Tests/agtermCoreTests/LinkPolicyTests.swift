import Foundation
import Testing
@testable import agtermCore

struct LinkPolicyTests {
    // MARK: disposition (open / reveal / ignore)

    /// The garbage suffixes model a `String(cString:)` over-read past `len`: the trailing space + junk
    /// leave the URL unparseable or non-web, so it can never come back `.open`.
    @Test func trailingGarbageDoesNotYieldAWebURL() {
        #expect(LinkPolicy.disposition(for: "https://example.com\u{00}/etc/other", localHosts: Self.localHosts) == .ignore)
        #expect(LinkPolicy.disposition(for: "https://example.com extra junk", localHosts: Self.localHosts) == .ignore)
    }

    /// A fixed injected set so host matching is deterministic in tests (independent of the real machine).
    static let localHosts: Set<String> = ["myhost", "localhost"]

    @Test(arguments: [
        "http://example.com",
        "https://example.com/path?q=1#frag",
        "HTTPS://EXAMPLE.COM",
        "mailto:someone@example.com",
        "ftp://host/file.txt",
    ])
    func webSchemesOpen(_ raw: String) throws {
        let expected = try #require(URL(string: raw))
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .open(expected))
    }

    /// A local `file://` reveals the HOST-STRIPPED, dot-normalized path — Finder never sees the original
    /// authority — so every host form of `/tmp/x.bin` resolves to the same plain `file:///tmp/x.bin`.
    @Test(arguments: [
        ("file:///tmp/x.bin", "file:///tmp/x.bin"),            // empty host
        ("file:/tmp/x.bin", "file:///tmp/x.bin"),              // authority-less (single-slash) form → no host
        ("file://localhost/tmp/x.bin", "file:///tmp/x.bin"),   // localhost — host stripped
        ("file://myhost/tmp/x.bin", "file:///tmp/x.bin"),      // this machine's own name (GNU ls) — host stripped
        ("file://MYHOST/tmp/x.bin", "file:///tmp/x.bin"),      // host match is case-insensitive
        ("file://myhost./tmp/x.bin", "file:///tmp/x.bin"),     // trailing FQDN dot is stripped
        ("FILE:///tmp/x.bin", "file:///tmp/x.bin"),            // scheme match is case-insensitive
        ("file:///tmp/../tmp/x.bin", "file:///tmp/x.bin"),     // dot segments normalized away
        ("file://myhost/tmp/a%20b.bin", "file:///tmp/a%20b.bin"),  // percent-encoded space survives the round-trip
        ("file:///Applications/Some.app", "file:///Applications/Some.app"),  // revealed in Finder, NOT launched
    ])
    func localFileReveals(_ raw: String, _ expected: String) {
        guard case let .reveal(url) = LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
        #expect(url.absoluteString == expected)
    }

    @Test(arguments: [
        "file:///net/server/share/x.bin",         // /net (-hosts) auto-mount root
        "file:///Network/Servers/host/share",     // /Network auto-mount root
        "file:///home/someone/x.bin",              // /home (auto_home) auto-mount root
        "file://localhost/net/server/share",      // local host but an auto-mount path
        "file:///tmp/../net/server/share",        // dot segments resolve INTO /net — must still ignore
        "file:///tmp/%2E%2E/net/server/share",    // percent-encoded `..` decodes BEFORE normalization — still ignore
        "file:///NET/server/share",               // auto-mount match is case-insensitive
        "file:///net",                            // bare root (no child) — exercises the `lower == root` branch
        "file:///home",                           // bare root
        "file:///network",                        // bare root
        "file:///System/Volumes/Data/home/someone/x.bin",     // canonical Data path where auto_home really mounts
        "file:///System/Volumes/Data/net/server/share",      // canonical Data /net
        "file:///System/Volumes/Data/Network/Servers/host",  // canonical Data /Network/Servers
    ])
    func autoMountPathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    /// Sibling names that merely start with an auto-mount root are NOT auto-mount paths — still revealed.
    /// The last case is the boundary that keeps the Data denylist narrow: a normal file on the Data volume
    /// (`/System/Volumes/Data/Users/…`, where every real file lives) must reveal, not be treated as automount.
    @Test(arguments: [
        ("file:///networkx/x.bin", "file:///networkx/x.bin"),
        ("file:///nettools/x.bin", "file:///nettools/x.bin"),
        ("file:///homebrew/x.bin", "file:///homebrew/x.bin"),
        ("file:///System/Volumes/Data/Users/me/doc.bin", "file:///System/Volumes/Data/Users/me/doc.bin"),
    ])
    func autoMountLookalikesStillReveal(_ raw: String, _ expected: String) {
        guard case let .reveal(url) = LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
        #expect(url.absoluteString == expected)
    }

    /// The classifier never resolves symlinks: revealing a link INSIDE a symlinked directory keeps the LINK
    /// path, not the resolved target — so a `link -> /net` can never be followed into an automount root.
    @Test func revealDoesNotResolveSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agt-linkpolicy-symlink-test", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // the real leaf MUST exist, else `resolvingSymlinksInPath()` also returns the link path and the test
        // could not tell the lexical normalizer from a symlink-resolving regression.
        try Data().write(to: target.appendingPathComponent("x.bin"))
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }
        let linkLeaf = base.appendingPathComponent("link").appendingPathComponent("x.bin")
        guard case let .reveal(url) = LinkPolicy.disposition(for: linkLeaf.absoluteString, localHosts: Self.localHosts) else {
            Issue.record("expected .reveal for \(linkLeaf.absoluteString)"); return
        }
        // reveal keeps the LINK path; a regression to resolvingSymlinksInPath() would yield .../target/x.bin
        #expect(url.path(percentEncoded: false) == linkLeaf.path(percentEncoded: false))
    }

    /// An empty or relative `file://` path is ignored — an empty path would make `URL(fileURLWithPath:)`
    /// resolve to the process working directory, revealing the wrong thing.
    @Test(arguments: [
        "file://localhost",   // local host, no path
        "file://myhost",      // local host, no path
        "file:relative",      // relative path, no leading slash
    ])
    func emptyOrRelativeFilePathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    @Test(arguments: [
        "file://otherhost/tmp/x.txt",             // non-local host → ignore (would trip a Finder network mount)
        "file://remote.example.com/share/x.txt",
    ])
    func nonLocalFileIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    // a decoded NUL made open() read the name before it while eligibility judged the suffix after it
    @Test(arguments: ["file:///tmp/id_rsa%00.go", "file:///tmp/id_rsa%00.md", "file://localhost/tmp/a%0A.txt",
                      "file:///tmp/a%00.go:3"])
    func aFileLinkDecodingToAControlCharacterIsIgnoredAndOffersNothing(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
        #expect(LinkPolicy.locations(for: raw, origin: .pane(Self.session), cwd: "/w", localHosts: Self.localHosts).isEmpty)
    }

    @Test(arguments: [
        "javascript:alert(1)",
        "vscode://file/x",
        "tel:+15550100",
        "example.com",
        "",
        "   ",
    ])
    func otherSchemesIgnore(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    @Test(arguments: [
        "file:////server/share/x.txt",          // empty host, UNC-style path — remote target hidden in the path
        "file://localhost//server/share/x.txt",  // local host but UNC path — still a network target
        "file://localhost/%2Fserver/share",     // encoded slash decodes to a leading // — still a UNC target
    ])
    func uncPathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    // MARK: bare paths and images

    static let home = "/Users/me"

    @Test(arguments: [
        ("/tmp/shot.png", "/tmp/shot.png"),
        ("/tmp/shot.PNG", "/tmp/shot.PNG"),
        ("/tmp/a b.jpg", "/tmp/a b.jpg"),
        ("/tmp/x.jpeg", "/tmp/x.jpeg"),
        ("/tmp/x.gif", "/tmp/x.gif"),
        ("/tmp/x.webp", "/tmp/x.webp"),
        ("/tmp/100%#?.png", "/tmp/100%#?.png"),
        ("/tmp/../tmp/x.png", "/tmp/x.png"),
        ("~/shots/x.png", "/Users/me/shots/x.png"),
        ("file:///tmp/x.png", "/tmp/x.png"),
        ("file://localhost/tmp/x.PNG", "/tmp/x.PNG"),
    ])
    func localImagePathsShowAsImages(_ raw: String, _ path: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts, home: Self.home)
            == .image(URL(fileURLWithPath: path, isDirectory: false)))
    }

    @Test(arguments: [
        ("/tmp/notes.bin", "/tmp/notes.bin"),
        ("/tmp/x.svg", "/tmp/x.svg"),
        ("/tmp/x.pdf", "/tmp/x.pdf"),
        ("/usr/bin", "/usr/bin"),
        ("/tmp/png", "/tmp/png"),
        ("~/notes.bin", "/Users/me/notes.bin"),
    ])
    func otherBarePathsReveal(_ raw: String, _ path: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts, home: Self.home)
            == .reveal(URL(fileURLWithPath: path, isDirectory: false)))
    }

    @Test(arguments: [
        "//server/share/x.png",
        "/net/host/x.png",
        "/tmp/../net/x.png",
        "/home/someone/x.png",
        "~",
        "~user/x.png",
        "src/x.png",
        "./x.png",
        "/tmp/x.png\u{00}/etc/other",
        "/tmp/x\ny.png",
    ])
    func unsafeOrRelativeBarePathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts, home: Self.home) == .ignore)
    }

    @Test(arguments: LinkOpenMode.allCases, [LinkPolicy.ClickOrigin.pane(session), .scratch(session)])
    func imagesOpenOnTheOwningSessionInEveryMode(_ mode: LinkOpenMode, _ origin: LinkPolicy.ClickOrigin) {
        let url = URL(fileURLWithPath: "/tmp/shot.png", isDirectory: false)
        for raw in ["/tmp/shot.png", "file:///tmp/shot.png"] {
            #expect(LinkPolicy.route(for: raw, mode: mode, origin: origin, localHosts: Self.localHosts, home: Self.home)
                == .image(url, session: Self.session))
        }
    }

    @Test(arguments: [LinkPolicy.ClickOrigin.hud, .programOverlay, .quick])
    func sessionlessOriginsRevealImages(_ origin: LinkPolicy.ClickOrigin) {
        #expect(LinkPolicy.route(for: "/tmp/shot.png", mode: .overlay, origin: origin, localHosts: Self.localHosts, home: Self.home)
            == .reveal(URL(fileURLWithPath: "/tmp/shot.png", isDirectory: false)))
    }

    @Test(arguments: [
        ("/tmp/notes.md", "/tmp/notes.md"),
        ("/tmp/README.MARKDOWN", "/tmp/README.MARKDOWN"),
        ("~/plan.md", "/Users/me/plan.md"),
        ("file:///tmp/a%20b.md", "/tmp/a b.md"),
        ("file://localhost/tmp/x.markdown", "/tmp/x.markdown"),
    ])
    func localMarkdownPathsRenderAsMarkdown(_ raw: String, _ path: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts, home: Self.home)
            == .markdown(URL(fileURLWithPath: path, isDirectory: false)))
    }

    @Test(arguments: LinkOpenMode.allCases, [LinkPolicy.ClickOrigin.pane(session), .scratch(session)])
    func markdownOpensOnTheOwningSessionAtItsModeSize(_ mode: LinkOpenMode, _ origin: LinkPolicy.ClickOrigin) {
        let url = URL(fileURLWithPath: "/tmp/notes.md", isDirectory: false)
        let percent = mode == .browser ? 95 : mode.overlaySizePercent
        for raw in ["/tmp/notes.md", "file:///tmp/notes.md"] {
            #expect(LinkPolicy.route(for: raw, mode: mode, origin: origin, localHosts: Self.localHosts, home: Self.home)
                == .markdown(url, session: Self.session, sizePercent: percent))
        }
    }

    @Test(arguments: [LinkPolicy.ClickOrigin.hud, .programOverlay, .quick])
    func sessionlessOriginsRevealMarkdown(_ origin: LinkPolicy.ClickOrigin) {
        #expect(LinkPolicy.route(for: "/tmp/notes.md", mode: .overlay, origin: origin, localHosts: Self.localHosts, home: Self.home)
            == .reveal(URL(fileURLWithPath: "/tmp/notes.md", isDirectory: false)))
    }

    @Test(arguments: [(false, 95), (true, 75)] as [(Bool, Int?)])
    func commandShiftOpensMarkdownAtTheBrowserSizeUnlessTheMouseIsCaptured(_ captured: Bool, _ percent: Int?) {
        let origin = LinkPolicy.ClickOrigin.pane(Self.session)
        let browser = LinkPolicy.wantsBrowser(modifiers: [.command, .shift], mode: .overlay75, origin: origin, mouseCaptured: captured)
        let route = LinkPolicy.route(for: "/tmp/notes.md", mode: browser ? .browser : .overlay75, origin: origin,
                                     localHosts: Self.localHosts, home: Self.home)
        #expect(route == .markdown(URL(fileURLWithPath: "/tmp/notes.md", isDirectory: false), session: Self.session, sizePercent: percent))
    }

    @Test(arguments: [
        ("/tmp/agdoc/pr.html", "/tmp/agdoc/pr.html"),
        ("/tmp/INDEX.HTM", "/tmp/INDEX.HTM"),
        ("~/page.html", "/Users/me/page.html"),
        ("file:///tmp/a%20b.html", "/tmp/a b.html"),
    ])
    func localHtmlPathsOpenAsDocuments(_ raw: String, _ path: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts, home: Self.home)
            == .document(URL(fileURLWithPath: path, isDirectory: false)))
    }

    @Test(arguments: LinkOpenMode.allCases, [LinkPolicy.ClickOrigin.pane(session), .scratch(session)])
    func documentOpensOnTheOwningSessionAtItsModeSize(_ mode: LinkOpenMode, _ origin: LinkPolicy.ClickOrigin) {
        let url = URL(fileURLWithPath: "/tmp/pr.html", isDirectory: false)
        let percent = mode == .browser ? 95 : mode.overlaySizePercent
        for raw in ["/tmp/pr.html", "file:///tmp/pr.html"] {
            #expect(LinkPolicy.route(for: raw, mode: mode, origin: origin, localHosts: Self.localHosts, home: Self.home)
                == .document(url, session: Self.session, sizePercent: percent))
        }
    }

    @Test(arguments: [LinkPolicy.ClickOrigin.hud, .programOverlay, .quick])
    func sessionlessOriginsRevealDocuments(_ origin: LinkPolicy.ClickOrigin) {
        #expect(LinkPolicy.route(for: "/tmp/pr.html", mode: .overlay, origin: origin, localHosts: Self.localHosts, home: Self.home)
            == .reveal(URL(fileURLWithPath: "/tmp/pr.html", isDirectory: false)))
    }

    // a bare path in a pane attached from another Mac names a file on that Mac
    @Test func remotePaneIgnoresBarePathsAndRevealsFileLinks() throws {
        let origin = LinkPolicy.ClickOrigin.remotePane(Self.session)
        let route = { (raw: String) in
            LinkPolicy.route(for: raw, mode: .overlay, origin: origin, localHosts: Self.localHosts, home: Self.home)
        }
        #expect(route("/tmp/shot.png") == .ignore)
        #expect(route("~/notes.txt") == .ignore)
        #expect(route("file:///tmp/shot.png") == .reveal(URL(fileURLWithPath: "/tmp/shot.png", isDirectory: false)))
        #expect(route("/tmp/notes.md") == .ignore)
        #expect(route("file:///tmp/notes.md") == .reveal(URL(fileURLWithPath: "/tmp/notes.md", isDirectory: false)))
        #expect(route("/tmp/pr.html") == .ignore)
        #expect(route("file:///tmp/pr.html") == .reveal(URL(fileURLWithPath: "/tmp/pr.html", isDirectory: false)))
        let web = try #require(URL(string: "https://example.com/a"))
        #expect(route("https://example.com/a") == .overlay(web, session: Self.session, sizePercent: nil))
    }

    // MARK: localHostNames / expandedHostNames (the default-parameter source)

    @Test func expandedHostNamesNormalizesAndAddsLocalShortForm() {
        let out = LinkPolicy.expandedHostNames(from: ["MyMac.local", "Box.", "localhost", "", ".local"])
        #expect(out.contains("mymac.local"))
        #expect(out.contains("mymac"))          // .local short form added alongside
        #expect(out.contains("box"))            // trailing FQDN dot dropped + lowercased
        #expect(out.contains("localhost"))
        #expect(!out.contains(""))              // empty name skipped, and a bare ".local" adds no empty short form
    }

    @Test func localHostNamesAlwaysHasLocalhostAndIsNonEmpty() {
        #expect(LinkPolicy.localHostNames.contains("localhost"))
        #expect(!LinkPolicy.localHostNames.isEmpty)
    }

    /// Smoke test on the DEFAULT `localHosts` parameter: without injection the decision must reach
    /// `localHostNames`, so an empty-host / localhost file link still reveals (host-stripped).
    @Test(arguments: ["file:///tmp/x.bin", "file://localhost/tmp/x.bin"])
    func defaultLocalHostsRevealLocalFiles(_ raw: String) {
        guard case let .reveal(url) = LinkPolicy.disposition(for: raw) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
        #expect(url.absoluteString == "file:///tmp/x.bin")
    }

    // MARK: route (browser / overlay / reveal / ignore)

    static let session = UUID()
    static let origins: [LinkPolicy.ClickOrigin] = [.pane(session), .remotePane(session), .scratch(session), .hud, .programOverlay, .quick]

    @Test(arguments: ["http://example.com/a", "https://example.com/a?q=1"], origins)
    func browserModeSendsWebLinksToTheBrowser(_ raw: String, _ origin: LinkPolicy.ClickOrigin) throws {
        let url = try #require(URL(string: raw))
        #expect(LinkPolicy.route(for: raw, mode: .browser, origin: origin, localHosts: Self.localHosts) == .browser(url))
    }

    @Test(arguments: ["http://localhost:5173/a", "HTTPS://example.com/a"],
          [LinkPolicy.ClickOrigin.pane(session), .scratch(session)])
    func overlayModeOpensPaneAndScratchWebLinksOnTheOwningSession(_ raw: String, _ origin: LinkPolicy.ClickOrigin) throws {
        let url = try #require(URL(string: raw))
        #expect(LinkPolicy.route(for: raw, mode: .overlay, origin: origin, localHosts: Self.localHosts)
            == .overlay(url, session: Self.session, sizePercent: nil))
    }

    @Test(arguments: [(LinkOpenMode.overlay, nil), (.overlay95, 95), (.overlay75, 75), (.overlay50, 50)] as [(LinkOpenMode, Int?)])
    func eachOverlayModeCarriesItsSizeToTheRoute(_ mode: LinkOpenMode, _ percent: Int?) throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(LinkPolicy.route(for: "https://example.com/a", mode: mode, origin: .pane(Self.session), localHosts: Self.localHosts)
            == .overlay(url, session: Self.session, sizePercent: percent))
    }

    // regression: a plain-http page the app's web views cannot load was routed to the overlay
    @Test(arguments: [
        ("http://localhost/", true), ("http://LOCALHOST:8080/x", true), ("http://devbox/", true),
        ("http://mac.local:3000/", true), ("http://127.0.0.1:5173/", true), ("http://93.184.216.34/", true),
        ("http://[::1]:8080/", true), ("http://[2001:db8::1]/", true),
        ("http://example.com/", false), ("http://www.example.com:8080/a", false), ("http://local/", true),
        ("http://notlocal.localx/", false), ("http://1.2.3.example/", false), ("http://999.1.1.1/", false),
        ("https://example.com/", true),
    ])
    func overlayModeTakesPlainHttpOnlyFromHostsAWebViewMayLoad(_ raw: String, _ overlay: Bool) throws {
        let url = try #require(URL(string: raw))
        let route = LinkPolicy.route(for: raw, mode: .overlay, origin: .pane(Self.session), localHosts: Self.localHosts)
        #expect(route == (overlay ? .overlay(url, session: Self.session, sizePercent: nil) : .browser(url)))
    }

    @Test(arguments: [LinkPolicy.ClickOrigin.hud, .programOverlay, .quick])
    func overlayModeKeepsSessionlessOriginsInTheBrowser(_ origin: LinkPolicy.ClickOrigin) throws {
        let url = try #require(URL(string: "https://example.com"))
        #expect(LinkPolicy.route(for: "https://example.com", mode: .overlay, origin: origin, localHosts: Self.localHosts)
            == .browser(url))
    }

    @Test(arguments: ["mailto:someone@example.com", "ftp://host/file.txt"], LinkOpenMode.allCases)
    func nonWebSchemesAlwaysGoToTheSystemHandler(_ raw: String, _ mode: LinkOpenMode) throws {
        let url = try #require(URL(string: raw))
        #expect(LinkPolicy.route(for: raw, mode: mode, origin: .pane(Self.session), localHosts: Self.localHosts) == .browser(url))
    }

    @Test(arguments: LinkOpenMode.allCases, origins)
    func fileLinksRevealAndOtherSchemesStayIgnoredInEveryMode(_ mode: LinkOpenMode, _ origin: LinkPolicy.ClickOrigin) {
        #expect(LinkPolicy.route(for: "file:///tmp/x.bin", mode: mode, origin: origin, localHosts: Self.localHosts)
            == .reveal(URL(fileURLWithPath: "/tmp/x.bin", isDirectory: false)))
        #expect(LinkPolicy.route(for: "x-custom://run", mode: mode, origin: origin, localHosts: Self.localHosts) == .ignore)
        #expect(LinkPolicy.route(for: "file://elsewhere/tmp/x.txt", mode: mode, origin: origin, localHosts: Self.localHosts) == .ignore)
    }

    @Test(arguments: [LinkOpenMode.overlay, .overlay95, .overlay75, .overlay50],
          [LinkPolicy.ClickOrigin.pane(session), .scratch(session)])
    func commandShiftAsksForTheBrowserInEveryOverlayMode(_ mode: LinkOpenMode, _ origin: LinkPolicy.ClickOrigin) {
        #expect(LinkPolicy.wantsBrowser(modifiers: [.command, .shift], mode: mode, origin: origin, mouseCaptured: false))
        #expect(!LinkPolicy.wantsBrowser(modifiers: [.command, .shift], mode: .browser, origin: origin, mouseCaptured: false))
    }

    @Test(arguments: [
        KeyModifiers.command.rawValue, KeyModifiers.shift.rawValue, 0,
        KeyModifiers([.command, .shift, .option]).rawValue, KeyModifiers([.command, .shift, .control]).rawValue,
        KeyModifiers([.command, .option]).rawValue,
    ])
    func onlyTheExactCommandShiftChordAsksForTheBrowser(_ raw: Int) {
        #expect(!LinkPolicy.wantsBrowser(modifiers: KeyModifiers(rawValue: raw), mode: .overlay, origin: .pane(Self.session), mouseCaptured: false))
    }

    @Test(arguments: [LinkPolicy.ClickOrigin.pane(session), .scratch(session)])
    func commandShiftUnderMouseCaptureFollowsTheSetting(_ origin: LinkPolicy.ClickOrigin) {
        #expect(!LinkPolicy.wantsBrowser(modifiers: [.command, .shift], mode: .overlay, origin: origin, mouseCaptured: true))
    }

    @Test(arguments: [LinkPolicy.ClickOrigin.hud, .programOverlay, .quick])
    func sessionlessOriginsNeverTakeTheOverride(_ origin: LinkPolicy.ClickOrigin) {
        #expect(!LinkPolicy.wantsBrowser(modifiers: [.command, .shift], mode: .overlay, origin: origin, mouseCaptured: false))
    }

    // MARK: text pages and line locations

    private static func loc(_ path: String, _ line: Int? = nil) -> LinkPolicy.LinkLocation {
        LinkPolicy.LinkLocation(path: path, line: line)
    }

    private static func locations(_ raw: String, cwd: String? = nil,
                                  origin: LinkPolicy.ClickOrigin = .pane(session)) -> [LinkPolicy.LinkLocation] {
        LinkPolicy.locations(for: raw, origin: origin, cwd: cwd, localHosts: localHosts, home: home)
    }

    @Test(arguments: ["/tmp/a.go", "/tmp/notes.txt", "file:///tmp/Makefile", "file://localhost/tmp/.zshrc", "~/a.swift"])
    func eligibleLocalFilesAreTextPages(_ raw: String) {
        guard case .text(_, let line) = LinkPolicy.disposition(for: raw, localHosts: Self.localHosts, home: Self.home) else {
            Issue.record("expected .text for \(raw)"); return
        }
        #expect(line == nil)
    }

    // regression: an absolute compiler location read its suffix as the extension and was revealed
    @Test func anAbsoluteLocationNamesTheLiteralPathThenTheFileAtItsLine() {
        #expect(Self.locations("/x/a.go:42:7") == [Self.loc("/x/a.go:42:7"), Self.loc("/x/a.go", 42)])
        #expect(Self.locations("/x/a.go:42") == [Self.loc("/x/a.go:42"), Self.loc("/x/a.go", 42)])
        #expect(Self.locations("file:///x/a.go:9") == [Self.loc("/x/a.go:9"), Self.loc("/x/a.go", 9)])
    }

    // regression: a relative compiler location was parsed as a URL scheme and ignored
    @Test func aRelativeLocationJoinsThePaneDirectoryBeforeAnySchemeParse() {
        #expect(Self.locations("./a.go:42", cwd: "/w") == [Self.loc("/w/a.go:42"), Self.loc("/w/a.go", 42)])
        #expect(Self.locations("src/a.go:3:1", cwd: "/w/") == [Self.loc("/w/src/a.go:3:1"), Self.loc("/w/src/a.go", 3)])
        #expect(Self.locations("../lib/b.rs:10", cwd: "/w/app") == [Self.loc("/w/lib/b.rs:10"), Self.loc("/w/lib/b.rs", 10)])
        #expect(Self.locations("src/a.go", cwd: "/w") == [Self.loc("/w/src/a.go")])
    }

    // regression: a path printed at the end of a sentence kept the period and never opened
    @Test func sentencePunctuationAfterAPathNamesTheLiteralThenEachShorterSpelling() {
        #expect(Self.locations("/tmp/review.md.") == [Self.loc("/tmp/review.md."), Self.loc("/tmp/review.md")])
        #expect(Self.locations("/tmp/a.md?") == [Self.loc("/tmp/a.md?"), Self.loc("/tmp/a.md")])
        #expect(Self.locations("/tmp/a.md;") == [Self.loc("/tmp/a.md;"), Self.loc("/tmp/a.md")])
        #expect(Self.locations("/tmp/a.md?!") == [Self.loc("/tmp/a.md?!"), Self.loc("/tmp/a.md?"), Self.loc("/tmp/a.md")])
        #expect(Self.locations("~/a.md.") == [Self.loc(Self.home + "/a.md."), Self.loc(Self.home + "/a.md")])
        #expect(Self.locations("src/a.md.", cwd: "/w") == [Self.loc("/w/src/a.md."), Self.loc("/w/src/a.md")])
        #expect(Self.locations("file:///tmp/a.md.") == [Self.loc("/tmp/a.md."), Self.loc("/tmp/a.md")])
    }

    @Test func aLocationEndingASentenceFindsTheFileAtItsLine() {
        #expect(Self.locations("/a/b.swift:12.") == [Self.loc("/a/b.swift:12."), Self.loc("/a/b.swift:12"), Self.loc("/a/b.swift", 12)])
        #expect(Self.locations("/a/b.swift.:12") == [Self.loc("/a/b.swift.:12"), Self.loc("/a/b.swift.", 12)])
    }

    @Test func atMostThreeTrailingPunctuationCharactersAreTrimmed() {
        #expect(Self.locations("/tmp/a.md...") == [Self.loc("/tmp/a.md..."), Self.loc("/tmp/a.md.."), Self.loc("/tmp/a.md."),
                                                   Self.loc("/tmp/a.md")])
        #expect(!Self.locations("/tmp/a.md....").contains(Self.loc("/tmp/a.md")))
        let long = "/tmp/a" + String(repeating: "!", count: 10_000)
        #expect(Self.locations(long).count == 4)
        #expect(Self.locations(long).last == Self.loc("/tmp/a" + String(repeating: "!", count: 9_997)))
    }

    @Test(arguments: ["/tmp/x/..", "/tmp/x/.", "/tmp/x/.!", "/tmp/...", "/tmp/?!", "/.", "/tmp/a,", "/tmp/a)", "/tmp/a:"])
    func aNameOfPunctuationAloneOrOtherTrailingCharactersOffersNoShorterSpelling(_ raw: String) {
        #expect(Self.locations(raw).isEmpty)
    }

    @Test(arguments: ["/net.", "/net/host/a.md.", "/Network.", "/home/me/a.md?", "//host/share/a.md.", "/tmp/../net/a.md."])
    func aTrimmedSpellingInsideARefusedRootIsNeverOffered(_ raw: String) {
        #expect(!Self.locations(raw).contains { LinkPolicy.isAutomountPath($0.path) || $0.path.hasPrefix("//") })
    }

    @Test func aRemotePaneOffersNoShorterSpelling() {
        #expect(Self.locations("/tmp/a.md.", origin: .remotePane(Self.session)).isEmpty)
    }

    @Test(arguments: ["/x/a.go", "/x/a.go:", "/x/a.go:0", "/x/a.go:-3", "/x/a.go:abc", "/x/a.go:4x",
                      "/x/a.go:99999999999999999999", "/x/:12"])
    func anAbsolutePathWithoutAValidLineNeedsNoLookup(_ raw: String) {
        #expect(Self.locations(raw).isEmpty)
    }

    @Test(arguments: ["http://localhost:3000", "https://host:8443", "https://host:8443/a.go:3", "mailto:a@b.c",
                      "x-custom://run/a.go:3", "file://otherhost/x/a.go:3", "file:////server/share/a.go:3"])
    func webAndForeignLinksAreNeverPaths(_ raw: String) {
        #expect(Self.locations(raw, cwd: "/w").isEmpty)
    }

    @Test(arguments: ["/net/x/a.go:3", "/Network/a.go:3", "/home/me/a.go:3", "/tmp/../net/x/a.go:3",
                      "//host/share/a.go:3", "/System/Volumes/Data/home/me/a.go:3"])
    func refusedAbsolutePathsOfferNothingToStat(_ raw: String) {
        #expect(Self.locations(raw, cwd: "/w").isEmpty)
    }

    @Test(arguments: [nil, "", "rel/dir", "/net/x", "/w\u{07}", "/w\nx", "//host/share", "/Network"] as [String?])
    func aRelativePathUnderAMissingOrRefusedDirectoryOffersNothing(_ cwd: String?) {
        #expect(Self.locations("src/a.go:3", cwd: cwd).isEmpty)
        #expect(Self.locations("./a.go:3", cwd: cwd).isEmpty)
    }

    @Test func aRelativePathEscapingIntoAnAutomountRootOffersNothing() {
        #expect(Self.locations("../../net/x/a.go:3", cwd: "/w/app").isEmpty)
        #expect(Self.locations("../../../home/x/a.go:3", cwd: "/w/a/b").isEmpty)
    }

    @Test func aRemotePaneOffersNothingToStat() {
        #expect(Self.locations("/x/a.go:42", origin: .remotePane(Self.session)).isEmpty)
        #expect(Self.locations("./a.go:42", cwd: "/w", origin: .remotePane(Self.session)).isEmpty)
        #expect(Self.locations("file:///x/a.go:42", origin: .remotePane(Self.session)).isEmpty)
    }

    @Test func noFoundCandidateKeepsTodaysRoute() {
        let route = { (raw: String) in
            LinkPolicy.route(for: raw, mode: .overlay, origin: .pane(Self.session), localHosts: Self.localHosts, home: Self.home)
        }
        #expect(route("/x/a.go:42") == .reveal(URL(fileURLWithPath: "/x/a.go:42", isDirectory: false)))
        #expect(route("./a.go:42") == .ignore)
        #expect(route("src/a.go:42") == .ignore)
    }

    @Test(arguments: LinkOpenMode.allCases)
    func aFoundLocationOpensAsTextAtItsLineFromAPaneOrTheScratch(_ mode: LinkOpenMode) {
        let size = mode == .browser ? 95 : mode.overlaySizePercent
        let url = URL(fileURLWithPath: "/x/a.go", isDirectory: false)
        for origin in [LinkPolicy.ClickOrigin.pane(Self.session), .scratch(Self.session)] {
            #expect(LinkPolicy.route(for: Self.loc("/x/a.go", 42), mode: mode, origin: origin)
                == .text(LinkPolicy.TextLink(url: url, line: 42, session: Self.session, sizePercent: size)))
        }
        #expect(LinkPolicy.route(for: "/x/a.go", mode: mode, origin: .pane(Self.session), localHosts: Self.localHosts)
            == .text(LinkPolicy.TextLink(url: url, line: nil, session: Self.session, sizePercent: size)))
    }

    @Test(arguments: [LinkPolicy.ClickOrigin.remotePane(session), .hud, .programOverlay, .quick])
    func aTextFileFromAnotherOriginIsRevealed(_ origin: LinkPolicy.ClickOrigin) {
        let url = URL(fileURLWithPath: "/x/a.go", isDirectory: false)
        #expect(LinkPolicy.route(for: Self.loc("/x/a.go", 42), mode: .overlay, origin: origin) == .reveal(url))
        #expect(LinkPolicy.route(for: "file:///x/a.go", mode: .overlay, origin: origin, localHosts: Self.localHosts) == .reveal(url))
    }

    @Test func aFoundLocationKeepsTheImageAndMarkdownRoutesAndRevealsTheRest() {
        let session = Self.session
        #expect(LinkPolicy.route(for: Self.loc("/x/a.png", 3), mode: .overlay, origin: .pane(session))
            == .image(URL(fileURLWithPath: "/x/a.png", isDirectory: false), session: session))
        #expect(LinkPolicy.route(for: Self.loc("/x/r.md", 3), mode: .overlay, origin: .pane(session))
            == .markdown(URL(fileURLWithPath: "/x/r.md", isDirectory: false), session: session, sizePercent: nil))
        #expect(LinkPolicy.route(for: Self.loc("/x/a.go:42"), mode: .overlay, origin: .pane(session))
            == .reveal(URL(fileURLWithPath: "/x/a.go:42", isDirectory: false)))
    }

    // MARK: click intent

    @Test(arguments: [
        ([KeyModifiers.command], false, LinkPolicy.ClickIntent.normal),
        ([.command, .shift], false, .browser),
        ([.command, .option], false, .reveal),
        ([.command, .option, .shift], false, .normal),
        ([.option], false, .normal),
        ([.command, .control], false, .normal),
        ([.command, .option, .control], false, .normal),
        ([.command], true, .normal),
        ([.command, .shift], true, .normal),
        ([.command, .option], true, .normal),
        ([.command, .option, .shift], true, .reveal),
    ] as [(KeyModifiers, Bool, LinkPolicy.ClickIntent)])
    func theChordDecidesTheClickIntent(_ modifiers: KeyModifiers, _ captured: Bool, _ intent: LinkPolicy.ClickIntent) {
        #expect(LinkPolicy.clickIntent(modifiers: modifiers, mode: .overlay, origin: .pane(Self.session), mouseCaptured: captured) == intent)
    }

    @Test(arguments: LinkOpenMode.allCases, origins)
    func theRevealChordWorksInEveryModeAndOrigin(_ mode: LinkOpenMode, _ origin: LinkPolicy.ClickOrigin) {
        #expect(LinkPolicy.clickIntent(modifiers: [.command, .option], mode: mode, origin: origin, mouseCaptured: false) == .reveal)
        #expect(LinkPolicy.clickIntent(modifiers: [.command, .option, .shift], mode: mode, origin: origin, mouseCaptured: true) == .reveal)
    }

    @Test func aLocalRouteNamesItsFileAndAWebOrIgnoredOneNone() throws {
        let file = URL(fileURLWithPath: "/x/a.go", isDirectory: false)
        let web = try #require(URL(string: "https://example.com/"))
        let session = Self.session
        #expect(LinkPolicy.Route.image(file, session: session).localFile == file)
        #expect(LinkPolicy.Route.markdown(file, session: session, sizePercent: 95).localFile == file)
        #expect(LinkPolicy.Route.document(file, session: session, sizePercent: 95).localFile == file)
        #expect(LinkPolicy.Route.text(LinkPolicy.TextLink(url: file, line: 3, session: session, sizePercent: nil)).localFile == file)
        #expect(LinkPolicy.Route.reveal(file).localFile == file)
        #expect(LinkPolicy.Route.browser(web).localFile == nil)
        #expect(LinkPolicy.Route.overlay(web, session: session, sizePercent: nil).localFile == nil)
        #expect(LinkPolicy.Route.ignore.localFile == nil)
    }

    @Test(arguments: [("/x/app.log", nil, true), ("/x/run.OUT", nil, true), ("/x/app.log", 42, false), ("/x/notes.txt", nil, false),
                      ("/x/a.go", nil, false)] as [(String, Int?, Bool)])
    func onlyAPlainClickOnALogOpensAsALogPage(_ path: String, _ line: Int?, _ expected: Bool) {
        let link = LinkPolicy.TextLink(url: URL(fileURLWithPath: path, isDirectory: false), line: line, session: Self.session,
                                       sizePercent: nil)

        #expect(link.opensAsLog == expected)
    }
}
