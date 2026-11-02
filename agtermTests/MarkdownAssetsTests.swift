import XCTest
@testable import agterm

final class MarkdownAssetsTests: XCTestCase {
    func testTheAppBundleCarriesTheRendererInDependencyOrderAndTheStylesheet() throws {
        let assets = MarkdownAssets(bundle: .main)

        let library = try XCTUnwrap(assets.script.range(of: "markdown-it 14.1.0"))
        let highlight = try XCTUnwrap(assets.script.range(of: "Highlight.js v11.11.1"))
        let render = try XCTUnwrap(assets.script.range(of: "getElementById('agterm-markdown')"))
        XCTAssertLessThan(library.lowerBound, highlight.lowerBound)
        XCTAssertLessThan(highlight.lowerBound, render.lowerBound)
        XCTAssertTrue(assets.style.contains("--agterm-foreground"))
        for license in ["markdown-it-14.1.0", "highlight-11.11.1"] {
            XCTAssertNotNil(Bundle.main.url(forResource: license, withExtension: "LICENSE", subdirectory: "markdown"), license)
        }
    }

    func testTheTextRendererCarriesHighlightJsWithoutTheMarkdownParser() throws {
        let assets = MarkdownAssets(bundle: .main)

        let highlight = try XCTUnwrap(assets.textScript.range(of: "Highlight.js v11.11.1"))
        let render = try XCTUnwrap(assets.textScript.range(of: "getElementById('agterm-text')"))
        XCTAssertLessThan(highlight.lowerBound, render.lowerBound)
        XCTAssertNil(assets.textScript.range(of: "markdown-it"))
        let shared = try XCTUnwrap(assets.textStyle.range(of: "--agterm-foreground"))
        let own = try XCTUnwrap(assets.textStyle.range(of: ".agterm-gutter"))
        XCTAssertLessThan(shared.lowerBound, own.lowerBound)
    }

    func testABundleWithoutTheFolderReadsEmpty() {
        let assets = MarkdownAssets(bundle: Bundle(for: MarkdownAssetsTests.self))

        XCTAssertEqual(assets.script, ";\n;\n")
        XCTAssertEqual(assets.style, "")
        XCTAssertEqual(assets.textScript, ";\n")
        XCTAssertEqual(assets.textStyle, "\n")
    }
}
