import Foundation
import Testing
@testable import agtermCore

struct MarkdownPageTests {
    private let folder: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("img"), withIntermediateDirectories: true)
        folder = url.resolvingSymlinksInPath().path
    }

    private func image(_ reference: String, _ path: String) -> MarkdownPage.Image {
        MarkdownPage.Image(reference: reference, path: path)
    }

    private func touch(_ relative: String) throws -> String {
        let path = folder + "/" + relative
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func theSourceAndTheImageMapStayInertText() {
        let source = "</pre><script>alert(1)</script> <img src=x onerror=y> & \"q\" 'a'"
        let images = MarkdownPage.Embedded(uris: ["data:image/png;base64,AA=="], references: ["a\"><script>": 0])
        let html = MarkdownPage.html(markdown: source, images: images, style: "p{}")

        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img"))
        #expect(html.contains("&lt;/pre&gt;&lt;script&gt;alert(1)&lt;/script&gt; &lt;img src=x onerror=y&gt; &amp; &quot;q&quot; &#39;a&#39;"))
        #expect(html.contains(#"data-images="{&quot;references&quot;:{&quot;a\&quot;&gt;&lt;script&gt;&quot;:0},&quot;uris&quot;:[&quot;data:image\/png;base64,AA==&quot;]}""#))
        #expect(html.contains("default-src 'none'; img-src data:; style-src 'unsafe-inline'"))
        #expect(html.contains("<style>p{}</style>"))
    }

    // regression: a quote or bracket fused with a combining mark is one Character and skipped escaping
    @Test func aMetacharacterFollowedByACombiningMarkIsStillEscaped() {
        let images = MarkdownPage.Embedded(uris: ["data:image/png;base64,AA=="], references: ["x\"\u{301} data-test=1.png": 0])
        let html = MarkdownPage.html(markdown: "<\u{301}b>", images: images, style: "")

        #expect(html.contains("x\\&quot;\u{301} data-test=1.png"))
        #expect(html.contains("&lt;\u{301}b&gt;"))
    }

    @Test func inlineAndReferenceImagesInsideTheFolderResolve() throws {
        let shot = try touch("img/shot.png")
        let ref = try touch("ref.jpg")
        let markdown = "![a](img/shot.png) ![b](./img/shot.png) ![c][r]\n\n[r]: ref.jpg\n"

        let found = MarkdownPage.imageReferences(in: markdown, folder: folder)

        #expect(found == [image("img/shot.png", shot), image("./img/shot.png", shot), image("ref.jpg", ref)])
    }

    @Test func spacedAndNonASCIINamesAreKeyedDecoded() throws {
        let spaced = try touch("my shot.png")
        let accented = try touch("café.png")

        let found = MarkdownPage.imageReferences(in: "![a](<my shot.png>) ![b](my%20shot.png) ![c](café.png)", folder: folder)

        #expect(found == [image("my shot.png", spaced), image("café.png", accented)])
    }

    @Test(arguments: ["https://x.io/a.png", "data:image/png;base64,AA==", "../outside.png", "~/a.png", "/etc/hosts", "img/missing/../../.."])
    func remoteDataAndEscapingReferencesAreLeftOut(_ reference: String) throws {
        #expect(MarkdownPage.imageReferences(in: "![x](\(reference))", folder: folder).isEmpty)
    }

    @Test func anAbsoluteOrFileReferenceInsideTheFolderResolves() throws {
        let shot = try touch("img/shot.png")

        #expect(MarkdownPage.localPath(shot, folder: folder) == shot)
        #expect(MarkdownPage.localPath("file://" + shot, folder: folder) == nil, "the renderer drops file: sources, so none is read")
    }

    @Test func anOutwardSymlinkIsRefusedAndAnInwardOneResolvesToItsTarget() throws {
        let fm = FileManager.default
        let outside = fm.temporaryDirectory.appendingPathComponent("agterm-md-out-\(UUID().uuidString).png").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: outside))
        defer { try? fm.removeItem(atPath: outside) }
        try fm.createSymbolicLink(atPath: folder + "/out.png", withDestinationPath: outside)
        let shot = try touch("img/shot.png")
        try fm.createSymbolicLink(atPath: folder + "/in.png", withDestinationPath: shot)

        let found = MarkdownPage.imageReferences(in: "![o](out.png) ![i](in.png) ![s](img/shot.png)", folder: folder)

        #expect(found == [image("in.png", shot), image("img/shot.png", shot)])
    }

    @Test func remoteReferencesIgnoreSymlinksOnThisMac() throws {
        let fm = FileManager.default
        let outside = fm.temporaryDirectory.appendingPathComponent("agterm-md-out-\(UUID().uuidString).png").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: outside))
        defer { try? fm.removeItem(atPath: outside) }
        try fm.createSymbolicLink(atPath: folder + "/out.png", withDestinationPath: outside)

        let found = MarkdownPage.remoteImageReferences(in: "![o](out.png) ![m](img/missing.png) ![e](../up.png)", folder: folder)

        #expect(found == [image("out.png", folder + "/out.png"), image("img/missing.png", folder + "/img/missing.png")])
    }

    @Test(arguments: [("a.png", "/f/a.png"), ("img/../b.png", "/f/b.png"), ("/f/c.png", "/f/c.png")] as [(String, String)])
    func lexicalPathJoinsAndNormalizesInsideTheFolder(reference: String, expected: String) {
        #expect(MarkdownPage.lexicalPath(reference, folder: "/f") == expected)
    }

    @Test(arguments: ["../a.png", "/etc/hosts", "~/a.png", "https://x.io/a.png", "", "."])
    func lexicalPathRefusesWhatLeavesTheFolder(_ reference: String) {
        #expect(MarkdownPage.lexicalPath(reference, folder: "/f") == nil)
    }

    @Test func aSymlinkedFolderStillContainsItsOwnPictures() throws {
        let fm = FileManager.default
        let link = fm.temporaryDirectory.appendingPathComponent("agterm-md-link-\(UUID().uuidString)").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: folder)
        defer { try? fm.removeItem(atPath: link) }
        let shot = try touch("img/shot.png")

        #expect(MarkdownPage.imageReferences(in: "![s](img/shot.png)", folder: link) == [image("img/shot.png", shot)])
    }

    @Test func aLinkGrantNamesTheCanonicalFileAndItsFolder() throws {
        let fm = FileManager.default
        let readme = try touch("README.md")
        let link = fm.temporaryDirectory.appendingPathComponent("agterm-md-link-\(UUID().uuidString)").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: folder)
        defer { try? fm.removeItem(atPath: link) }

        #expect(MarkdownPage.linkGrant(for: readme) == MarkdownLinkGrant(path: readme, root: folder))
        #expect(MarkdownPage.linkGrant(for: link + "/README.md") == MarkdownLinkGrant(path: readme, root: folder))
    }

    @Test func aSymlinkedFirstFileIsGrantedItsTargetsFolder() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder + "/docs", withIntermediateDirectories: true)
        let target = try touch("docs/README.md")
        try fm.createSymbolicLink(atPath: folder + "/README.md", withDestinationPath: target)

        #expect(MarkdownPage.linkGrant(for: folder + "/README.md") == MarkdownLinkGrant(path: target, root: folder + "/docs"))
    }

    @Test func noGrantForTheRootOrHomeFolderOrANonMarkdownTarget() throws {
        let fm = FileManager.default
        let home = try touch("README.md").replacingOccurrences(of: "/README.md", with: "")
        let alias = fm.temporaryDirectory.appendingPathComponent("agterm-md-home-\(UUID().uuidString)").path
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: home)
        defer { try? fm.removeItem(atPath: alias) }
        let notes = try touch("notes.txt")
        try fm.createSymbolicLink(atPath: folder + "/disguised.md", withDestinationPath: notes)

        #expect(MarkdownPage.linkGrant(for: "/README.md") == nil)
        #expect(MarkdownPage.linkGrant(for: folder + "/README.md", home: home) == nil)
        #expect(MarkdownPage.linkGrant(for: alias + "/README.md", home: home) == nil)
        #expect(MarkdownPage.linkGrant(for: folder + "/disguised.md") == nil)
        #expect(MarkdownPage.linkGrant(for: "README.md") == nil)
    }

    @Test func aLinkedDocumentInsideTheRootIsReadAtItsNormalizedRequestedPath() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder + "/sub", withIntermediateDirectories: true)
        let grant = MarkdownLinkGrant(path: try touch("README.md"), root: folder)
        let nested = try touch("sub/b.markdown")
        try fm.createSymbolicLink(atPath: folder + "/alias.md", withDestinationPath: nested)

        #expect(MarkdownPage.linkedDocument(grant.path, grant: grant) == grant.path)
        #expect(MarkdownPage.linkedDocument(nested, grant: grant) == nested)
        #expect(MarkdownPage.linkedDocument(folder + "/sub/../README.md", grant: grant) == folder + "/README.md")
        #expect(MarkdownPage.linkedDocument(folder + "/alias.md", grant: grant) == folder + "/alias.md")
    }

    @Test func aLinkedDocumentOutsideTheRootOrNotMarkdownIsRefused() throws {
        let fm = FileManager.default
        let grant = MarkdownLinkGrant(path: try touch("README.md"), root: folder)
        let outside = fm.temporaryDirectory.appendingPathComponent("agterm-md-out-\(UUID().uuidString).md").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: outside))
        defer { try? fm.removeItem(atPath: outside) }
        try fm.createSymbolicLink(atPath: folder + "/out.md", withDestinationPath: outside)
        let env = try touch(".env")
        try fm.createSymbolicLink(atPath: folder + "/guide.md", withDestinationPath: env)
        _ = try touch("notes.txt")

        for requested in [folder + "/../x.md", outside, "/etc/x.md", folder + "/out.md", folder + "/guide.md",
                          folder + "/notes.txt", folder, folder + "/", "sub/b.md", ""] {
            #expect(MarkdownPage.linkedDocument(requested, grant: grant) == nil, "\(requested)")
        }
    }

    @Test func linksAreFlaggedOnlyWhenAsked() {
        let flag = #"data-links="local""#
        #expect(!MarkdownPage.html(markdown: "x", images: .init(), style: "").contains(flag))
        #expect(MarkdownPage.html(markdown: "x", images: .init(), style: "", links: true).contains(flag))
    }

    @Test func remoteReferencesSkipAMarkdownSpelledPicture() {
        let found = MarkdownPage.remoteImageReferences(in: "![d](guide.md) ![m](x.MARKDOWN) ![p](a.png)", folder: "/f")

        #expect(found == [image("a.png", "/f/a.png")])
    }

    @Test func limitsAreSet() {
        #expect(MarkdownPage.maxBytes == 4 << 20)
        #expect(MarkdownPage.maxImageBytes == 32 << 20)
        #expect(MarkdownPage.maxImagePixels == ImagePage.maxPixels)
    }
}
