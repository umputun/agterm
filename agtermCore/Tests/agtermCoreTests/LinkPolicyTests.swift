import Foundation
import Testing
@testable import agtermCore

struct LinkPolicyTests {
    @Test(arguments: [
        "http://example.com",
        "https://example.com/path?q=1#frag",
        "HTTPS://EXAMPLE.COM",           // scheme match is case-insensitive
        "mailto:someone@example.com",
        "ftp://host/file.txt",
    ])
    func permitsWebAndMailSchemes(_ raw: String) {
        #expect(LinkPolicy.permittedURL(from: raw) != nil)
    }

    @Test(arguments: [
        "file:///Applications/Evil.app",  // LaunchServices would launch it — must be rejected
        "file:///etc/passwd",
        "javascript:alert(1)",
        "vscode://file/x",                // custom app scheme
        "tel:+15550100",
        "example.com",                    // no scheme
        "",                               // empty
        "   ",                            // whitespace only
    ])
    func rejectsNonWebAndSchemelessInputs(_ raw: String) {
        #expect(LinkPolicy.permittedURL(from: raw) == nil)
    }

    @Test func returnsTheParsedURLUnchanged() {
        #expect(LinkPolicy.permittedURL(from: "https://example.com/a")?.absoluteString == "https://example.com/a")
    }

    /// A URL followed by garbage (what the pre-fix `String(cString:)` over-read past `len` could produce)
    /// does not silently become a valid link: the trailing space + junk make it unparseable or non-web.
    @Test func trailingGarbageDoesNotYieldAWebURL() {
        #expect(LinkPolicy.permittedURL(from: "https://example.com\u{00}/etc/other") == nil)
        #expect(LinkPolicy.permittedURL(from: "https://example.com extra junk") == nil)
    }

    // MARK: disposition (open / reveal / ignore)

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

    @Test(arguments: [
        "file:///tmp/x.md",                // empty host
        "file:/tmp/x.md",                  // authority-less (single-slash) form → no host
        "file://localhost/tmp/x.md",       // localhost
        "file://myhost/tmp/x.md",          // this machine's own name (what GNU ls --hyperlink emits)
        "file://MYHOST/tmp/x.md",          // host match is case-insensitive
        "file://myhost./tmp/x.md",         // trailing FQDN dot is stripped
        "FILE:///tmp/x.md",                // scheme match is case-insensitive
        "file:///Applications/Some.app",   // revealed in Finder, NOT launched
    ])
    func localFileReveals(_ raw: String) throws {
        let expected = try #require(URL(string: raw))
        #expect(LinkPolicy.disposition(for: raw, localHosts: Self.localHosts) == .reveal(expected))
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
    /// `localHostNames`, so an empty-host / localhost file link still reveals.
    @Test(arguments: ["file:///tmp/x.md", "file://localhost/tmp/x.md"])
    func defaultLocalHostsRevealLocalFiles(_ raw: String) throws {
        let expected = try #require(URL(string: raw))
        #expect(LinkPolicy.disposition(for: raw) == .reveal(expected))
    }
}
