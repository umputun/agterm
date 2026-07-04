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
}
