import Foundation
import Testing
@testable import agtermCore

struct TextPageTests {
    @Test func theTextStaysInertAndThePolicyLoadsNothing() {
        let source = "</pre><script>alert(1)</script> <img src=x onerror=y> <iframe src=a> & \"q\" 'a'"
        let html = TextPage.html(text: source, language: "swift", line: 3, style: "p{}")

        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img"))
        #expect(!html.contains("<iframe"))
        #expect(html.contains("&lt;/pre&gt;&lt;script&gt;alert(1)&lt;/script&gt; &lt;img src=x onerror=y&gt; &lt;iframe src=a&gt; &amp; &quot;q&quot; &#39;a&#39;"))
        #expect(html.contains(#"content="default-src 'none'; style-src 'unsafe-inline'""#))
        #expect(!html.contains("img-src"))
        #expect(html.contains(#"<div id="agterm-text" hidden data-language="swift" data-line="3">"#))
        #expect(html.contains("<style>p{}</style>"))
    }

    // regression: a quote or bracket fused with a combining mark is one Character and skipped escaping
    @Test func aMetacharacterFollowedByACombiningMarkIsStillEscaped() {
        let html = TextPage.html(text: "<\u{301}b> \"\u{301}", language: nil, line: nil, style: "")

        #expect(html.contains("&lt;\u{301}b&gt; &quot;\u{301}"))
    }

    @Test func noLanguageOrLineLeavesTheAttributesOut() {
        let html = TextPage.html(text: "x", language: nil, line: nil, style: "")

        #expect(html.contains(#"<div id="agterm-text" hidden>x</div>"#))
    }

    // regression: a newline right after <pre> is dropped by the parser and shifted every line number
    @Test func aLeadingBlankLineSurvivesInTheHolder() {
        let html = TextPage.html(text: "\n\nfunc a()", language: nil, line: nil, style: "")

        #expect(html.contains(#"<div id="agterm-text" hidden>"# + "\n\nfunc a()</div>"))
        #expect(!html.contains("<pre"))
    }

    @Test func textOverTheHighlightCapRendersPlain() {
        let atCap = String(repeating: "a", count: TextPage.maxHighlightBytes)
        let overCap = atCap + "é"

        #expect(TextPage.html(text: atCap, language: "go", line: nil, style: "").contains(#"data-language="go""#))
        #expect(!TextPage.html(text: overCap, language: "go", line: nil, style: "").contains("data-language"))
    }

    @Test(arguments: [
        ("a.swift", "swift"), ("a.go", "go"), ("a.py", "python"), ("a.rb", "ruby"), ("a.rs", "rust"),
        ("a.js", "javascript"), ("a.mjs", "javascript"), ("a.cjs", "javascript"), ("a.ts", "typescript"),
        ("a.c", "c"), ("a.h", "c"), ("a.cc", "cpp"), ("a.cpp", "cpp"), ("a.cxx", "cpp"), ("a.hpp", "cpp"),
        ("a.m", "objectivec"), ("a.mm", "objectivec"), ("a.java", "java"), ("a.kt", "kotlin"), ("a.kts", "kotlin"),
        ("a.cs", "csharp"), ("a.php", "php"), ("a.pl", "perl"), ("a.pm", "perl"), ("a.lua", "lua"), ("a.r", "r"),
        ("a.sql", "sql"), ("a.css", "css"), ("a.scss", "scss"), ("a.less", "less"), ("a.graphql", "graphql"),
        ("a.sh", "bash"), ("a.bash", "bash"), ("a.zsh", "bash"), ("a.json", "json"), ("a.yaml", "yaml"),
        ("a.yml", "yaml"), ("a.toml", "ini"), ("a.ini", "ini"), ("a.cfg", "ini"), ("a.conf", "ini"),
        ("a.xml", "xml"), ("a.plist", "xml"), ("a.diff", "diff"), ("a.patch", "diff"), ("a.mk", "makefile"),
        ("a.vb", "vbnet"), ("/x/Makefile", "makefile"), ("/x/GNUmakefile", "makefile"), ("/x/.bashrc", "bash"),
        ("/x/.zshrc", "bash"), ("/x/.profile", "bash"), ("/x/.bash_profile", "bash"), ("/x/.zprofile", "bash"),
        ("/x/.gitconfig", "ini"), ("/x/.editorconfig", "ini"), ("/x/MAIN.GO", "go"), ("/x/y/Lib.Swift", "swift"),
    ])
    func mappedFilesGetTheirLanguage(path: String, language: String) {
        #expect(TextPage.language(forFile: path) == language)
        #expect(TextPage.isEligible(file: path))
    }

    @Test(arguments: [
        "a.txt", "a.TEXT", "a.log", "a.out", "a.csv", "a.tsv", "a.env", "/x/Cargo.lock", "/x/Dockerfile",
        "/x/LICENSE", "/x/README", "/x/CHANGELOG", "/x/Procfile", "/x/.gitignore", "/x/.env",
    ])
    func plainFilesAreEligibleWithNoLanguage(path: String) {
        #expect(TextPage.language(forFile: path) == nil)
        #expect(TextPage.isEligible(file: path))
    }

    @Test(arguments: [
        "a.md", "a.markdown", "a.html", "a.htm", "a.svg", "a.png", "a.pdf", "a.app", "a.command", "a.zip", "a.wasm",
        "/x/makefile", "/x/license", "/x/noext", "/x/dir/", "",
    ])
    func otherFilesAreNotTextPages(path: String) {
        #expect(!TextPage.isEligible(file: path))
    }

    @Test func validateAcceptsUTF8AndRefusesBinaries() {
        #expect(TextPage.validate(Data("héllo\n".utf8)) == "héllo\n")
        #expect(TextPage.validate(Data()) == "")
        #expect(TextPage.validate(Data([0xEF, 0xBB, 0xBF, 0x61])) != nil)
        #expect(TextPage.validate(Data([0x61, 0x00, 0x62])) == nil)
        #expect(TextPage.validate(Data([0xFF, 0xFE, 0x61])) == nil)
        #expect(TextPage.validate(Data([0x61, 0xC3])) == nil)
    }

    @Test(arguments: [("a.log", true), ("/x/y/APP.LOG", true), ("a.out", true), ("a.txt", false), ("a.log.gz", false),
                      ("/x/log", false), ("a.swift", false)])
    func onlyLogAndOutFilesAreLogs(path: String, isLog: Bool) {
        #expect(TextPage.isLog(file: path) == isLog)
    }

    @Test func aLogPageCarriesItsStateInsteadOfALine() {
        let log = TextLogState(following: true, report: TextLogReport(lines: 2, clipped: true, waiting: true, unreadable: true))
        let html = TextPage.html(text: "a\nb\n", language: nil, line: 7, style: "", log: log)

        #expect(html.contains(#"<div id="agterm-text" hidden data-log data-following="true" data-clipped data-waiting data-unreadable>"#))
        #expect(!html.contains("data-line"))
    }

    @Test func aPausedLogPageOmitsTheUnsetFlags() {
        let html = TextPage.html(text: "a", language: nil, line: nil, style: "", log: TextLogState(following: false))

        #expect(html.contains(#"<div id="agterm-text" hidden data-log data-following="false">a</div>"#))
    }

    @Test func aPausedLogPageCarriesItsAnchorAndAPlainPageNever() {
        let paused = TextPage.html(text: "a", language: nil, line: nil, style: "", log: TextLogState(following: false), anchor: 240.5)
        let plain = TextPage.html(text: "a", language: nil, line: nil, style: "", anchor: 240.5)
        let infinite = TextPage.html(text: "a", language: nil, line: nil, style: "", log: TextLogState(following: false),
                                     anchor: .infinity)

        #expect(paused.contains(#"data-anchor="240.5""#))
        #expect(!plain.contains("data-anchor"))
        #expect(!infinite.contains("data-anchor"))
    }
}
