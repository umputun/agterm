import Foundation
import Testing
@testable import agtermCore

struct LinkPolicyTests {
    // MARK: disposition (open / reveal / ignore)

    /// A URL followed by garbage (what the pre-fix `String(cString:)` over-read past `len` could produce)
    /// does not silently become an openable web link: the trailing space + junk make it unparseable or
    /// non-web, so the disposition is never `.open`.
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
    /// authority — so every host form of `/tmp/x.md` resolves to the same plain `file:///tmp/x.md`.
    @Test(arguments: [
        ("file:///tmp/x.md", "file:///tmp/x.md"),            // empty host
        ("file:/tmp/x.md", "file:///tmp/x.md"),              // authority-less (single-slash) form → no host
        ("file://localhost/tmp/x.md", "file:///tmp/x.md"),   // localhost — host stripped
        ("file://myhost/tmp/x.md", "file:///tmp/x.md"),      // this machine's own name (GNU ls) — host stripped
        ("file://MYHOST/tmp/x.md", "file:///tmp/x.md"),      // host match is case-insensitive
        ("file://myhost./tmp/x.md", "file:///tmp/x.md"),     // trailing FQDN dot is stripped
        ("FILE:///tmp/x.md", "file:///tmp/x.md"),            // scheme match is case-insensitive
        ("file:///tmp/../tmp/x.md", "file:///tmp/x.md"),     // dot segments normalized away
        ("file://myhost/tmp/a%20b.md", "file:///tmp/a%20b.md"),  // percent-encoded space survives the round-trip
        ("file:///Applications/Some.app", "file:///Applications/Some.app"),  // revealed in Finder, NOT launched
    ])
    func localFileReveals(_ raw: String, _ expected: String) {
        guard case let .reveal(url) = LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
        #expect(url.absoluteString == expected)
    }

    @Test(arguments: [
        "file:///net/server/share/x.md",         // /net (-hosts) auto-mount root
        "file:///Network/Servers/host/share",     // /Network auto-mount root
        "file:///home/someone/x.md",              // /home (auto_home) auto-mount root
        "file://localhost/net/server/share",      // local host but an auto-mount path
        "file:///tmp/../net/server/share",        // dot segments resolve INTO /net — must still ignore
        "file:///NET/server/share",               // auto-mount match is case-insensitive
    ])
    func autoMountPathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    /// Sibling names that merely start with an auto-mount root are NOT auto-mount paths — still revealed.
    @Test(arguments: ["file:///networkx/x.md", "file:///nettools/x.md", "file:///homebrew/x.md"])
    func autoMountLookalikesStillReveal(_ raw: String) {
        guard case .reveal = LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
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
        "file://otherhost/tmp/x.md",             // non-local host → ignore (would trip a Finder network mount)
        "file://remote.example.com/share/x.md",
    ])
    func nonLocalFileIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
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
        "file:////server/share/x.md",          // empty host, UNC-style path — remote target hidden in the path
        "file://localhost//server/share/x.md",  // local host but UNC path — still a network target
        "file://localhost/%2Fserver/share",     // encoded slash decodes to a leading // — still a UNC target
    ])
    func uncPathsIgnored(_ raw: String) {
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .ignore)
    }

    // MARK: localHostNames / expandedHostNames (the default-parameter source)

    @Test func expandedHostNamesNormalizesAndAddsLocalShortForm() {
        let out = LinkPolicy.expandedHostNames(from: ["MyMac.local", "Box.", "localhost", ""])
        #expect(out.contains("mymac.local"))
        #expect(out.contains("mymac"))          // .local short form added alongside
        #expect(out.contains("box"))            // trailing FQDN dot dropped + lowercased
        #expect(out.contains("localhost"))
        #expect(!out.contains(""))              // empty name skipped
    }

    @Test func localHostNamesAlwaysHasLocalhostAndIsNonEmpty() {
        #expect(LinkPolicy.localHostNames.contains("localhost"))
        #expect(!LinkPolicy.localHostNames.isEmpty)
    }

    /// Smoke test on the DEFAULT `localHosts` parameter: without injection the decision must reach
    /// `localHostNames`, so an empty-host / localhost file link still reveals (host-stripped).
    @Test(arguments: ["file:///tmp/x.md", "file://localhost/tmp/x.md"])
    func defaultLocalHostsRevealLocalFiles(_ raw: String) {
        guard case let .reveal(url) = LinkPolicy.disposition(for: raw) else {
            Issue.record("expected .reveal for \(raw)"); return
        }
        #expect(url.absoluteString == "file:///tmp/x.md")
    }
}
