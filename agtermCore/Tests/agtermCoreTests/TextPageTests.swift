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

    @Test func aDiffIsMarkedPastTheHighlightCapWithTheChangeItReopensOn() {
        let overCap = String(repeating: "a", count: TextPage.maxHighlightBytes + 1)

        let html = TextPage.html(text: overCap, language: "diff", line: nil, style: "", change: 4)

        #expect(html.contains(#"hidden data-diff data-change="4">"#))
        #expect(!html.contains("data-language"))
        #expect(!TextPage.html(text: "x", language: "diff", line: nil, style: "", change: 0).contains("data-change"))
    }

    @Test func aWrappedPageIsMarkedAndAnUnwrappedOneIsNot() {
        let log = TextLogState(following: true)

        #expect(TextPage.html(text: "x", language: nil, line: nil, style: "", wrap: true).contains(#"hidden data-wrap>"#))
        #expect(TextPage.html(text: "x", language: nil, line: nil, style: "", log: log, wrap: true).contains("data-wrap"))
        #expect(!TextPage.html(text: "x", language: nil, line: nil, style: "").contains("data-wrap"))
    }

    @Test func aDiffMapsEachHeaderPathToItsLanguage() {
        let text = """
            diff --git a/main.go b/main.go
            --- a/main.go
            +++ b/main.go
            --- /dev/null
            +++ "b/odd name.py"
            --- old.sql\t2026-11-06 10:00:00
            +++ notes.unknown
            """

        #expect(TextPage.diffLanguages(in: text) == [
            "a/main.go": "go", "b/main.go": "go", "\"b/odd name.py\"": "python", "old.sql": "sql",
        ])
    }

    @Test func aCRLFDiffMapsItsHeaderPaths() {
        #expect(TextPage.diffLanguages(in: "diff --git a/x.go b/x.go\r\n--- a/x.go\r\n+++ b/x.go\r\n") == ["a/x.go": "go", "b/x.go": "go"])
    }

    @Test func aColoredDiffMapsItsHeaderPathsWithoutTheEscapes() {
        let text = "\u{1B}[1mdiff --git a/x.go b/x.go\u{1B}[m\n\u{1B}[1m--- a/x.go\u{1B}[m\n\u{1B}[1m+++ b/x.go\u{1B}[m\n"
        #expect(TextPage.diffLanguages(in: text) == ["a/x.go": "go", "b/x.go": "go"])
    }

    @Test func aDiffUnderTheHighlightCapCarriesItsFileLanguages() {
        let text = "--- a/x.go\n+++ b/x.go\n@@ -1 +1 @@\n-a\n+b\n"
        let overCap = text + String(repeating: " x\n", count: TextPage.maxHighlightBytes / 3 + 1)

        #expect(TextPage.html(text: text, language: "diff", line: nil, style: "")
            .contains(#"data-files="{&quot;a\/x.go&quot;:&quot;go&quot;,&quot;b\/x.go&quot;:&quot;go&quot;}""#))
        #expect(!TextPage.html(text: overCap, language: "diff", line: nil, style: "").contains("data-files"))
        #expect(!TextPage.html(text: text, language: "go", line: nil, style: "").contains("data-files"))
        #expect(!TextPage.html(text: "-a\n+b\n", language: "diff", line: nil, style: "").contains("data-files"))
    }

    @Test func aGitDiffListsEveryFileSectionInPatchOrder() {
        let text = """
            diff --git a/main.go b/main.go
            index 1..2 100644
            --- a/main.go
            +++ b/main.go
            @@ -1 +1 @@
            -a
            +b
            diff --git a/new.py b/new.py
            new file mode 100644
            --- /dev/null
            +++ b/new.py
            @@ -0,0 +1 @@
            +x
            diff --git a/gone.sql b/gone.sql
            deleted file mode 100644
            --- a/gone.sql
            +++ /dev/null
            @@ -1 +0,0 @@
            -y
            diff --git a/old.txt b/moved.txt
            similarity index 100%
            rename from old.txt
            rename to moved.txt
            diff --git a/run.sh b/run.sh
            old mode 100644
            new mode 100755
            diff --git a/logo.png b/logo.png
            Binary files a/logo.png and b/logo.png differ
            """

        #expect(TextPage.diffSections(in: text) == [
            DiffSection(path: "main.go", line: 0), DiffSection(path: "new.py", line: 7),
            DiffSection(path: "gone.sql", line: 13), DiffSection(path: "moved.txt", line: 19),
            DiffSection(path: "run.sh", line: 23), DiffSection(path: "logo.png", line: 26),
        ])
    }

    @Test func aChangedRowThatReadsLikeAHeaderIsNoSection() {
        let text = """
            --- a/x.md
            +++ b/x.md
            @@ -1,2 +1,2 @@
             keep
            --- old rule
            +++ new rule
            diff --git a/y b/y
            --- a/y
            +++ b/y
            @@ -1 +1 @@
            -1
            +2
            """

        #expect(TextPage.diffSections(in: text) == [DiffSection(path: "b/x.md", line: 0), DiffSection(path: "y", line: 6)])
    }

    @Test func aPlainUnifiedDiffKeepsItsPathsAndDropsTheTimestamps() {
        let text = """
            --- old/a.c\t2026-11-06 10:00:00
            +++ new/a.c\t2026-11-06 10:05:00
            @@ -1 +1 @@
            -a
            +b
            --- old/b.c\t2026-11-06 10:00:00
            +++ new/b.c\t2026-11-06 10:05:00
            @@ -1 +1 @@
            -c
            +d
            """

        #expect(TextPage.diffSections(in: text) == [DiffSection(path: "new/a.c", line: 0), DiffSection(path: "new/b.c", line: 5)])
    }

    @Test func aDashedRowWithNoPlusRowAfterItOpensNoSection() {
        #expect(TextPage.diffSections(in: "subject\n--- \nnot a header\n").isEmpty)
    }

    @Test func aQuotedPathIsUnquoted() {
        let text = """
            diff --git "a/odd name.py" "b/odd name.py"
            --- "a/odd name.py"
            +++ "b/odd name.py"
            diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
            --- "a/caf\\303\\251.txt"
            +++ "b/caf\\303\\251.txt"
            """

        #expect(TextPage.diffSections(in: text) == [DiffSection(path: "odd name.py", line: 0), DiffSection(path: "café.txt", line: 3)])
    }

    @Test func aNoPrefixGitDiffKeepsItsPaths() {
        let text = "diff --git b/x.go b/x.go\n--- b/x.go\n+++ b/x.go\ndiff --git y.go y.go\nold mode 100644\nnew mode 100755\n"
        #expect(TextPage.diffSections(in: text) == [DiffSection(path: "b/x.go", line: 0), DiffSection(path: "y.go", line: 3)])
    }

    @Test func aCRLFOrColoredDiffListsItsSections() {
        #expect(TextPage.diffSections(in: "diff --git a/x.go b/x.go\r\n--- a/x.go\r\n+++ b/x.go\r\n") == [DiffSection(path: "x.go", line: 0)])
        let colored = "\u{1B}[1mdiff --git a/x.go b/x.go\u{1B}[m\n\u{1B}[1m--- a/x.go\u{1B}[m\n\u{1B}[1m+++ b/x.go\u{1B}[m\n"
        #expect(TextPage.diffSections(in: colored) == [DiffSection(path: "x.go", line: 0)])
    }

    // the page numbers lines after HTML turned every CR into a line break, so a lone CR shifted every later header
    @Test func aLoneCarriageReturnStartsALineAsTheParsedPageDoes() {
        let text = "--- a/x\n+++ b/x\n@@ -1,2 +1 @@\n-a\rb\n+c\ndiff --git a/y b/y\nold mode 100644\n"
        #expect(TextPage.diffSections(in: text) == [DiffSection(path: "b/x", line: 0), DiffSection(path: "y", line: 6)])
    }

    @Test func aRenameWithOnlyItsDestinationQuotedIsUnquoted() {
        let text = "diff --git a/old.txt \"b/caf\\303\\251.txt\"\nsimilarity index 100%\nrename from old.txt\nrename to \"caf\\303\\251.txt\"\n"
        #expect(TextPage.diffSections(in: text) == [DiffSection(path: "café.txt", line: 0)])
    }

    @Test func aDiffCarriesItsSectionsPastTheHighlightCap() {
        let text = "--- a/x.go\n+++ b/x.go\n@@ -1 +1 @@\n-a\n+b\n"
        let overCap = text + String(repeating: " x\n", count: TextPage.maxHighlightBytes / 3 + 1)
        let sections = #"data-sections="[{&quot;line&quot;:0,&quot;path&quot;:&quot;b\/x.go&quot;}]""#

        #expect(TextPage.html(text: text, language: "diff", line: nil, style: "").contains(sections))
        #expect(TextPage.html(text: overCap, language: "diff", line: nil, style: "").contains(sections))
        #expect(!TextPage.html(text: text, language: "go", line: nil, style: "").contains("data-sections"))
        #expect(!TextPage.html(text: "-a\n+b\n", language: "diff", line: nil, style: "").contains("data-sections"))
    }

    @Test func onlyAPlainDiffPageIsMarked() {
        let log = TextPage.html(text: "x", language: "diff", line: nil, style: "", log: TextLogState(following: true), change: 2)

        #expect(!log.contains("data-diff"))
        #expect(!log.contains("data-change"))
        #expect(!TextPage.html(text: "x", language: "go", line: nil, style: "", change: 2).contains("data-diff"))
    }

    @Test(arguments: [("a.diff", true), ("/x/b.PATCH", true), ("a.txt", false), ("a.go", false), ("diff", false)])
    func isDiffFollowsTheExtension(_ path: String, _ expected: Bool) {
        #expect(TextPage.isDiff(file: path) == expected)
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

    @Test func aRebuiltPageCarriesOnlyAFiniteAnchor() {
        let paused = TextPage.html(text: "a", language: nil, line: nil, style: "", log: TextLogState(following: false), anchor: 240.5)
        let plain = TextPage.html(text: "a", language: nil, line: 3, style: "", anchor: 80)
        let infinite = TextPage.html(text: "a", language: nil, line: nil, style: "", log: TextLogState(following: false),
                                     anchor: .infinity)
        let none = TextPage.html(text: "a", language: nil, line: nil, style: "")

        #expect(paused.contains(#"data-anchor="240.5""#))
        #expect(plain.contains(#"data-line="3" data-anchor="80.0""#))
        #expect(!infinite.contains("data-anchor"))
        #expect(!none.contains("data-anchor"))
    }

    @Test func aPageCarriesItsSearchWithTheQueryEscaped() {
        let html = TextPage.html(text: "a", language: nil, line: nil, style: "",
                                 search: TextPage.SearchState(query: #""><x>"#, revision: 4, current: 2))

        #expect(html.contains(#"<div id="agterm-text" hidden data-revision="4" data-query="&quot;&gt;&lt;x&gt;" data-current="2">"#))
    }

    @Test func aClosedSearchCarriesOnlyItsRevision() {
        let closed = TextPage.html(text: "a", language: nil, line: nil, style: "",
                                   search: TextPage.SearchState(query: "", revision: 5, current: 0))
        let none = TextPage.html(text: "a", language: nil, line: nil, style: "")

        #expect(closed.contains(#"<div id="agterm-text" hidden data-revision="5">"#))
        #expect(!none.contains("data-revision"))
    }
}
