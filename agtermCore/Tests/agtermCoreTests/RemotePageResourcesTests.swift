import Foundation
import Testing
@testable import agtermCore

struct RemotePageResourcesTests {
    let root: String
    let docs: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-resources-\(UUID().uuidString)")
        let docsURL = base.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsURL.appendingPathComponent("img"), withIntermediateDirectories: true)
        for file in ["docs/index.html", "docs/img/a.png", "secret.txt"] {
            try Data("x".utf8).write(to: base.appendingPathComponent(file))
        }
        try FileManager.default.createSymbolicLink(at: docsURL.appendingPathComponent("out.txt"),
                                                   withDestinationURL: base.appendingPathComponent("secret.txt"))
        root = base.resolvingSymlinksInPath().path
        docs = root + "/docs"
    }

    @Test func aGrantServesFilesInsideIt() {
        let source = HtmlSource.file(path: docs + "/index.html", grantRoot: docs)
        #expect(RemotePageResources.resolve(docs + "/index.html", source: source) == docs + "/index.html")
        #expect(RemotePageResources.resolve(docs + "/img/a.png", source: source) == docs + "/img/a.png")
    }

    @Test(arguments: ["/docs/../secret.txt", "/docs/out.txt", "/secret.txt", "/docs", "/docs/img/../../secret.txt"])
    func aGrantRefusesEscapes(_ relative: String) {
        let source = HtmlSource.file(path: docs + "/index.html", grantRoot: docs)
        #expect(RemotePageResources.resolve(root + relative, source: source) == nil)
    }

    @Test func noGrantServesOnlyThePagesOwnFile() {
        let source = HtmlSource.file(path: docs + "/index.html", grantRoot: nil)
        #expect(RemotePageResources.resolve(docs + "/index.html", source: source) == docs + "/index.html")
        #expect(RemotePageResources.resolve(docs + "/img/a.png", source: source) == nil)
    }

    @Test func aRelativePathOrAUrlPageServesNothing() throws {
        let file = HtmlSource.file(path: docs + "/index.html", grantRoot: docs)
        #expect(RemotePageResources.resolve("docs/index.html", source: file) == nil)
        let web = HtmlSource.url(try #require(URL(string: "https://example.com/")))
        #expect(RemotePageResources.resolve(docs + "/index.html", source: web) == nil)
    }
}
