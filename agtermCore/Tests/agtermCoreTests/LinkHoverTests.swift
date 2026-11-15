import Foundation
import Testing
@testable import agtermCore

struct LinkHoverTests {
    private let session = UUID()

    @Test func aPlainLinkIsShownAsIs() {
        #expect(LinkHover.label(for: "https://example.com/a?b=1", sessionName: { _ in "x" }) == "https://example.com/a?b=1")
    }

    @Test func aSessionLinkNamesTheSessionItSelects() {
        let link = "agterm://session/\(session.uuidString)"

        #expect(LinkHover.label(for: link, sessionName: { $0 == session ? "build" : nil }) == "Session: build")
        #expect(LinkHover.label(for: link, sessionName: { _ in nil }) == link)
    }

    @Test(arguments: ["\u{0007}", "\u{001B}", "\n", "\u{0085}", "\u{2028}", "\u{2029}", "\u{061C}", "\u{200E}", "\u{200F}",
                      "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
                      "\u{200B}", "\u{00AD}", "\u{2060}", "\u{FEFF}"])
    func aControlOrFormatScalarIsReplaced(_ scalar: String) {
        #expect(LinkHover.label(for: "https://a\(scalar)b.com", sessionName: { _ in nil }) == "https://a\u{FFFD}b.com")
    }

    @Test func aSessionNameIsNeutralizedToo() {
        let link = "agterm://session/\(session.uuidString)"

        #expect(LinkHover.label(for: link, sessionName: { _ in "a\u{202E}b\nc" }) == "Session: a\u{FFFD}b\u{FFFD}c")
    }

    @Test func aLongLinkIsCutInTheMiddle() {
        let link = "https://example.com/" + String(repeating: "x", count: 200) + "/end"

        let label = LinkHover.label(for: link, sessionName: { _ in nil })

        #expect(label.count == LinkHover.maxLength)
        #expect(label.hasPrefix("https://example.com/"))
        #expect(label.hasSuffix("/end"))
        #expect(label.contains("…"))
        #expect(LinkHover.label(for: String(repeating: "y", count: LinkHover.maxLength), sessionName: { _ in nil }).count
            == LinkHover.maxLength)
    }
}
