import Testing
@testable import agtermCore

struct TerminalTextTests {
    @Test func cleanStringUnchanged() {
        #expect(TerminalText.sanitized("user@host: ~/dev (main)") == "user@host: ~/dev (main)")
    }

    @Test func stripsNewlineAndCarriageReturn() {
        // the security-relevant case: a newline in an unquoted {AGT_X} splice is an sh -c command separator.
        #expect(TerminalText.sanitized("title\ninjected") == "titleinjected")
        #expect(TerminalText.sanitized("a\rb") == "ab")
        #expect(TerminalText.sanitized("a\r\nb") == "ab")
    }

    @Test func stripsTabNulEscAndDel() {
        #expect(TerminalText.sanitized("a\tb") == "ab")
        #expect(TerminalText.sanitized("a\u{00}b") == "ab")
        #expect(TerminalText.sanitized("a\u{1B}[31mb") == "a[31mb")
        #expect(TerminalText.sanitized("a\u{7F}b") == "ab")
    }

    @Test(arguments: 0..<0x20)
    func stripsEveryC0ControlCharacter(_ code: Int) {
        let scalar = Unicode.Scalar(code)!
        #expect(TerminalText.sanitized("a\(scalar)b") == "ab")
    }

    @Test func preservesPrintableUnicodeAndSpace() {
        #expect(TerminalText.sanitized("café 🚀 ~/项目") == "café 🚀 ~/项目")
    }

    @Test func emptyStaysEmpty() {
        #expect(TerminalText.sanitized("") == "")
    }

    @Test(arguments: [
        ("plain\ttext\n", "plain\ttext\n"),
        ("\u{1B}[1;38;5;208mbold\u{1B}[22m tail", "bold tail"),
        ("\u{1B}]8;;http://x\u{1B}\\link\u{1B}]8;;\u{07}", "link"),
        ("a\u{1B}(Bb\u{1B}=c", "abc"),
        ("end\u{1B}[38;2;1", "end"),
        ("end\u{1B}", "end"),
    ])
    func strippingEscapesDropsEverySequenceAndKeepsTheText(_ input: String, _ expected: String) {
        #expect(TerminalText.strippingEscapes(input) == expected)
    }
}
