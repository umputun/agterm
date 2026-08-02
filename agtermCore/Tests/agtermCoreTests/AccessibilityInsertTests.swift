import Testing
@testable import agtermCore

struct AccessibilityInsertTests {
    @Test func inlineTextTakesTheKeyboardPath() {
        #expect(AccessibilityInsert.needsPasteRouting("ls -la") == false)
        #expect(AccessibilityInsert.needsPasteRouting("") == false)
        #expect(AccessibilityInsert.needsPasteRouting("échō — ünïcode") == false)
    }

    @Test func lineFeedRoutesToPaste() {
        #expect(AccessibilityInsert.needsPasteRouting("ls -la\n"))
        #expect(AccessibilityInsert.needsPasteRouting("one\ntwo"))
    }

    @Test func carriageReturnRoutesToPaste() {
        #expect(AccessibilityInsert.needsPasteRouting("ls -la\r"))
        #expect(AccessibilityInsert.needsPasteRouting("one\rtwo"))
    }

    // The regression this helper exists for: CRLF is ONE grapheme cluster, so the previous
    // `contains("\n") || contains("\r")` predicate reported false and the payload skipped the
    // bracketed-paste branch — the raw CR reached the pty and the line ran.
    @Test func crlfRoutesToPaste() {
        #expect("ls -la\r\n".contains("\n") == false, "CRLF is one cluster, equal to neither \\n nor \\r")
        #expect("ls -la\r\n".contains("\r") == false)
        #expect(AccessibilityInsert.needsPasteRouting("ls -la\r\n"))
        #expect(AccessibilityInsert.needsPasteRouting("one\r\ntwo"))
    }

    // A tab reaches the shell as a completion keypress on the `insertText` path, so it belongs on the
    // bracketed-paste path exactly as a newline does — as does every other C0 control character.
    @Test func controlCharactersRouteToPaste() {
        #expect(AccessibilityInsert.needsPasteRouting("git\tcommit -m x"))
        #expect(AccessibilityInsert.needsPasteRouting("\u{1B}[A")) // ESC
        #expect(AccessibilityInsert.needsPasteRouting("a\u{00}b")) // NUL
        #expect(AccessibilityInsert.needsPasteRouting("a\u{7F}b")) // DEL
    }

    @Test func otherUnicodeLineBreaksRouteToPaste() {
        #expect(AccessibilityInsert.needsPasteRouting("a\u{0B}b")) // VT
        #expect(AccessibilityInsert.needsPasteRouting("a\u{0C}b")) // FF
        #expect(AccessibilityInsert.needsPasteRouting("a\u{85}b")) // NEL
        #expect(AccessibilityInsert.needsPasteRouting("a\u{2028}b")) // LS
        #expect(AccessibilityInsert.needsPasteRouting("a\u{2029}b")) // PS
    }
}
