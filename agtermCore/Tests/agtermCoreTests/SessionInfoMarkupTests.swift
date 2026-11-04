import Foundation
import Testing
@testable import agtermCore

struct SessionInfoMarkupTests {
    private func parse(_ source: String, markdown: Bool = true) throws -> [SessionInfoSpan] {
        try SessionInfoMarkup.spans(source, markdown: markdown)
    }

    private func rejection(_ source: String, markdown: Bool = true) -> SessionInfoMarkup.ParseError? {
        do {
            _ = try SessionInfoMarkup.spans(source, markdown: markdown)
            return nil
        } catch {
            return error
        }
    }

    @Test func plainTextKeepsMarkdownLiteral() throws {
        #expect(try parse("~/dev/*scratch*/notes_v2.md **x** ^[a](color: \"red\")", markdown: false)
            == [SessionInfoSpan(text: "~/dev/*scratch*/notes_v2.md **x** ^[a](color: \"red\")")])
    }

    @Test func inlineMarkdownMapsToTraits() throws {
        #expect(try parse("**3** agents *on* `rr`") == [
            SessionInfoSpan(text: "3", bold: true),
            SessionInfoSpan(text: " agents "),
            SessionInfoSpan(text: "on", italic: true),
            SessionInfoSpan(text: " "),
            SessionInfoSpan(text: "rr", code: true),
        ])
    }

    @Test func colorAndDimAttributesMapToSpans() throws {
        #expect(try parse("^[running](color: \"green\") ^[idle](dim: true) ^[x](color: 'Blue', dim: true)") == [
            SessionInfoSpan(text: "running", color: .green),
            SessionInfoSpan(text: " "),
            SessionInfoSpan(text: "idle", dim: true),
            SessionInfoSpan(text: " "),
            SessionInfoSpan(text: "x", dim: true, color: .blue),
        ])
    }

    @Test func boldInsideAColorBlockCombinesTraits() throws {
        #expect(try parse("^[**done** now](color: \"green\")") == [
            SessionInfoSpan(text: "done", bold: true, color: .green),
            SessionInfoSpan(text: " now", color: .green),
        ])
    }

    @Test func aLinkKeepsOnlyItsLabel() throws {
        #expect(try parse("see [PR 861](https://example.com/861) now") == [SessionInfoSpan(text: "see PR 861 now")])
    }

    @Test func anUnknownAttributeKeyRendersUnstyled() throws {
        #expect(try parse("^[a](colour: \"red\") b") == [SessionInfoSpan(text: "a b")])
    }

    @Test func badColorValuesAreRejected() {
        #expect(rejection("^[a](color: \"maroon\")") == .unknownColor("maroon"))
        #expect(rejection("^[a](color: \"#3a7bd5\")") == .unknownColor("#3a7bd5"))
        #expect(rejection("^[a](color: 42)") == .invalidMarkdown)
        #expect(rejection("^[a](color: red)") == .invalidMarkdown)
    }

    @Test func makeBuildsAValidatedInfo() throws {
        let info = try SessionInfo.make(source: "**3** ^[ok](color: \"green\")", markdown: true, hideAfter: 30).get()
        #expect(info.source == "**3** ^[ok](color: \"green\")")
        #expect(info.markdown)
        #expect(info.hideAfter == 30)
        #expect(info.spans == [SessionInfoSpan(text: "3", bold: true), SessionInfoSpan(text: " "),
                               SessionInfoSpan(text: "ok", color: .green)])
        let pink = try SessionInfo.make(source: "^[ok](color: \"pink\")", markdown: true, hideAfter: 0).get()
        #expect(pink.spans == [SessionInfoSpan(text: "ok", color: .pink)])
        let plain = try SessionInfo.make(source: "**3**", markdown: false, hideAfter: 0).get()
        #expect(plain.spans == [SessionInfoSpan(text: "**3**")])
    }

    @Test func makeCapsTheSourceInUTF8Bytes() {
        #expect((try? SessionInfo.make(source: String(repeating: "a", count: 512), markdown: false, hideAfter: 0).get()) != nil)
        #expect(SessionInfo.make(source: String(repeating: "a", count: 513), markdown: false, hideAfter: 0)
            == .failure(SessionInfoRejection(message: "info text is over 512 bytes")))
        #expect((try? SessionInfo.make(source: String(repeating: "é", count: 256), markdown: false, hideAfter: 0).get()) != nil)
        #expect(SessionInfo.make(source: String(repeating: "é", count: 257), markdown: false, hideAfter: 0)
            == .failure(SessionInfoRejection(message: "info text is over 512 bytes")))
    }

    @Test func makeRejectsAnOutOfRangeHideAfter() {
        for seconds in [-1, 86_401, Double.nan, Double.infinity] {
            #expect(SessionInfo.make(source: "x", markdown: false, hideAfter: seconds)
                == .failure(SessionInfoRejection(message: "--hide-after must be 0...86400 seconds")))
        }
        #expect((try? SessionInfo.make(source: "x", markdown: false, hideAfter: 86_400).get()) != nil)
    }

    @Test func makeReportsParseErrorsAsMessages() {
        #expect(SessionInfo.make(source: "^[a](color: \"maroon\")", markdown: true, hideAfter: 0)
            == .failure(SessionInfoRejection(
                message: "unknown info color: maroon (red|orange|yellow|green|blue|purple|gray|teal|pink|brown|indigo|mint)")))
        #expect(SessionInfo.make(source: "a\nb", markdown: false, hideAfter: 0)
            == .failure(SessionInfoRejection(message: "info text must be one line")))
        #expect(SessionInfo.make(source: "  ", markdown: false, hideAfter: 0)
            == .failure(SessionInfoRejection(message: "info text is empty")))
    }

    @Test func blankOrMultilineOrControlTextIsRejected() {
        #expect(rejection("") == .empty)
        #expect(rejection("   ", markdown: false) == .empty)
        #expect(rejection("&#32;&#32;") == .empty)
        #expect(rejection("^[ ](dim: true)") == .empty)
        #expect(rejection("a\nb", markdown: false) == .lineBreak)
        #expect(rejection("a&#10;b") == .lineBreak)
        #expect(rejection("a\u{2028}b", markdown: false) == .lineBreak)
        #expect(rejection("x &#27;[31m y") == .controlCharacter)
        #expect(rejection("a\tb", markdown: false) == .controlCharacter)
        #expect(rejection("a\u{9B}31mb", markdown: false) == .controlCharacter)
        #expect(rejection("a&#155;b") == .controlCharacter)
    }
}
