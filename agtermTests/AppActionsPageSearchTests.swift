import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppActionsPageSearchTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-actions-page-search-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
    }

    override func tearDown() async throws {
        actions = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    private func activeSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        return (store, try XCTUnwrap(store.activeSession))
    }

    func testEveryShownCoverOverTheFocusedPaneTakesCommandF() throws {
        let (store, session) = try activeSession()
        XCTAssertFalse(actions.coverTakesSearch(), "with nothing on top the terminal keeps ⌘F")
        let covers: [(String, HtmlOverlay?)] = [
            ("floating text page", HtmlOverlay(source: .text(path: "/tmp/a.txt", line: nil))),
            ("floating markdown page", HtmlOverlay(source: .markdown(path: "/tmp/a.md"))),
            ("floating program", nil),
        ]
        for (name, page) in covers {
            if let page {
                XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: 60), name)
            } else {
                XCTAssertTrue(store.openOverlay(session.id, command: "less", sizePercent: 60), name)
            }

            XCTAssertTrue(actions.coverTakesSearch(), name)
            XCTAssertTrue(store.closeOverlay(session.id), name)
        }
    }

    func testAHiddenPageOrAPageOverTheOtherPaneLeavesCommandFToTheTerminal() throws {
        let (store, session) = try activeSession()
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: HtmlOverlay(source: .markdown(path: "/tmp/a.md")),
                                           sizePercent: 60))
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)
        XCTAssertFalse(actions.coverTakesSearch(), "a hidden page is not on top")
        XCTAssertTrue(store.closeOverlay(session.id))

        store.toggleSplit(session.id)
        XCTAssertNil(store.openPaneOverlay(session.id, pane: .left, command: "htop"))
        session.splitFocused = true
        XCTAssertFalse(actions.coverTakesSearch(), "the focused right pane has nothing over it")
        session.splitFocused = false
        XCTAssertTrue(actions.coverTakesSearch(), "the focused left pane is under its own overlay")
    }
}
