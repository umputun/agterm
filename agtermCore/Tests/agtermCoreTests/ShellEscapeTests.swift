import Testing
@testable import agtermCore

struct ShellEscapeTests {
    @Test func plainPathUnchanged() {
        #expect(ShellEscape.path("/Users/me/image.png") == "/Users/me/image.png")
    }

    @Test func escapesSpacesAndParens() {
        #expect(ShellEscape.path("/Users/me/My File (1).txt") == "/Users/me/My\\ File\\ \\(1\\).txt")
    }

    @Test func escapesBackslashFirstWithoutDoubleEscaping() {
        // a literal backslash becomes \\, and a following space becomes \ (not re-escaped to \\ ).
        #expect(ShellEscape.path("a\\b c") == "a\\\\b\\ c")
    }

    @Test func escapesShellMetacharacters() {
        #expect(ShellEscape.path("a&b;c|d$e") == "a\\&b\\;c\\|d\\$e")
    }

    @Test func emptyStaysEmpty() {
        #expect(ShellEscape.path("") == "")
    }
}
