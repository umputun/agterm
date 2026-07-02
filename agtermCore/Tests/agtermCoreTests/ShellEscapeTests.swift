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

    @Test func escapesNewlinesSoADroppedNameCannotInjectACommand() {
        // a filename may contain a newline; unescaped it would submit the rest as a shell command via
        // inject(text:). Backslash-escaped, the line terminator can't terminate a command.
        #expect(ShellEscape.path("report.txt\ndate") == "report.txt\\\ndate")
        #expect(ShellEscape.path("a\rb") == "a\\\rb")
        #expect(ShellEscape.path("a\r\nb") == "a\\\r\\\nb")
    }

    @Test func emptyStaysEmpty() {
        #expect(ShellEscape.path("") == "")
    }
}
