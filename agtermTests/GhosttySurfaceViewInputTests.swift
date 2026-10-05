import XCTest
@testable import agterm
import agtermCore

@MainActor
final class GhosttySurfaceViewInputTests: XCTestCase {
    private var savedOpener = LinkOpener()

    private final class Followed {
        var opened: [URL] = []
        var revealed: [URL] = []
        var overlaid: [(URL, UUID)] = []
    }

    private func recordLinks(mode: LinkOpenMode, overlayOpens: Bool) -> Followed {
        let followed = Followed()
        LinkOpener.shared.mode = { mode }
        LinkOpener.shared.open = { followed.opened.append($0) }
        LinkOpener.shared.reveal = { followed.revealed.append($0) }
        LinkOpener.shared.overlay = { url, session in
            followed.overlaid.append((url, session))
            return overlayOpens
        }
        return followed
    }

    private func bareSurface() -> GhosttySurfaceView {
        GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
    }

    func testEachSurfaceKindNamesItsLinkClickOrigin() {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        pane.focusSession = session
        let scratch = bareSurface()
        scratch.watermarkSession = session
        scratch.focusSession = session
        let program = bareSurface()
        program.focusSession = session
        let hud = bareSurface()
        hud.focusSession = session
        hud.hudBodyFile = "/tmp/agterm-test-hud-body-missing"
        let quick = bareSurface()

        XCTAssertEqual(pane.linkClickOrigin, .pane(session.id))
        XCTAssertEqual(scratch.linkClickOrigin, .scratch(session.id))
        XCTAssertEqual(program.linkClickOrigin, .programOverlay)
        XCTAssertEqual(hud.linkClickOrigin, .hud)
        XCTAssertEqual(quick.linkClickOrigin, .quick)
        hud.hudBodyFile = nil
    }

    func testAPaneLinkGoesToTheOverlayInOverlayModeAndToTheBrowserWhenItCannotOpen() throws {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        let url = try XCTUnwrap(URL(string: "https://example.com/pr/1"))

        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        pane.openLink(url.absoluteString)
        XCTAssertEqual(shown.overlaid.map(\.0), [url])
        XCTAssertEqual(shown.overlaid.map(\.1), [session.id])
        XCTAssertTrue(shown.opened.isEmpty)

        let refused = recordLinks(mode: .overlay, overlayOpens: false)
        pane.openLink(url.absoluteString)
        XCTAssertEqual(refused.overlaid.count, 1)
        XCTAssertEqual(refused.opened, [url])
    }

    func testBrowserModeAHudAndNonWebLinksNeverReachTheOverlay() throws {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        let hud = bareSurface()
        hud.focusSession = session
        hud.hudBodyFile = "/tmp/agterm-test-hud-body-missing"
        defer { hud.hudBodyFile = nil }
        let web = try XCTUnwrap(URL(string: "https://example.com/"))
        let mail = try XCTUnwrap(URL(string: "mailto:a@example.com"))

        let browser = recordLinks(mode: .browser, overlayOpens: true)
        pane.openLink(web.absoluteString)
        XCTAssertEqual(browser.opened, [web])

        let overlay = recordLinks(mode: .overlay, overlayOpens: true)
        hud.openLink(web.absoluteString)
        pane.openLink(mail.absoluteString)
        pane.openLink("file:///tmp/x.md")
        pane.openLink("x-custom://run")
        XCTAssertEqual(overlay.opened, [web, mail])
        XCTAssertEqual(overlay.revealed, [URL(fileURLWithPath: "/tmp/x.md", isDirectory: false)])
        XCTAssertTrue(browser.overlaid.isEmpty && overlay.overlaid.isEmpty)
    }

    func testAnsweringFocusedAskReturnsKeysToItsTerminal() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let terminal = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        defer { terminal.teardown() }
        terminal.focusSession = fixture.session
        fixture.session.splitSurface = terminal
        fixture.session.splitFocused = true
        try fixture.open(pane: .right)
        fixture.mount()
        terminal.frame = CGRect(x: 300, y: 0, width: 300, height: 300)
        fixture.window.contentView?.addSubview(terminal, positioned: .below, relativeTo: nil)
        terminal.createSurface()
        let catcher = try XCTUnwrap(fixture.catcher)
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        fixture.window.makeFirstResponder(catcher)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: fixture.window.windowNumber, context: nil,
                                                 characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        catcher.keyDown(with: event)
        let deadline = Date(timeIntervalSinceNow: 1)
        while fixture.window.firstResponder !== terminal, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result.result, .answered)
        XCTAssertTrue(fixture.window.firstResponder === terminal)
    }

    func testUncoveredProgramOverlayClickLeavesTheAskPaneAndKeepsTypingAvailable() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(pane: .right)
        fixture.session.splitFocused = true
        fixture.mount()
        let terminal = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        defer { terminal.teardown() }
        terminal.focusSession = fixture.session
        fixture.session.overlayActive = true
        fixture.session.overlaySurface = terminal
        terminal.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        fixture.window.contentView?.addSubview(terminal, positioned: .below, relativeTo: nil)
        terminal.createSurface()
        XCTAssertNotNil(terminal.surface)
        fixture.catcher?.grabFocus()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 100),
                                                   modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        terminal.mouseDown(with: event)
        XCTAssertFalse(fixture.session.splitFocused)
        XCTAssertTrue(fixture.window.firstResponder === terminal)
        XCTAssertFalse(terminal.askBlocksFocus)
        XCTAssertNotNil(fixture.session.askPending)
    }

    func testMouseAndReparentFocusDoNotStealFromTheCoveredPaneAsk() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(pane: .right)
        fixture.session.splitFocused = true
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        let terminal = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        defer { terminal.teardown() }
        terminal.focusSession = fixture.session
        fixture.session.splitSurface = terminal
        terminal.frame = CGRect(x: 300, y: 0, width: 300, height: 300)
        fixture.window.contentView?.addSubview(terminal, positioned: .below, relativeTo: nil)
        terminal.createSurface()
        XCTAssertNotNil(terminal.surface)
        fixture.window.makeFirstResponder(catcher)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 350, y: 100),
                                                   modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        terminal.mouseDown(with: event)
        terminal.focusAfterReparent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
        XCTAssertTrue(fixture.window.firstResponder === catcher)
        XCTAssertTrue(terminal.askBlocksFocus)
        fixture.session.splitFocused = false
        XCTAssertFalse(terminal.askBlocksFocus)
    }

    private var surface: GhosttySurfaceView!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            savedOpener = LinkOpener.shared
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            surface = nil
            LinkOpener.shared = savedOpener
        }
        try await super.tearDown()
    }

    func testSelectedRangeIsAnEmptyInsertionPointWithoutAComposition() {
        XCTAssertFalse(surface.hasMarkedText())
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testSelectedRangeIsTheImeSelectionWhileComposing() {
        surface._markedRange = NSRange(location: 0, length: 5)
        surface._selectedRange = NSRange(location: 5, length: 0)
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testSelectedRangeDropsTheStaleImeSelectionOnceCompositionEnds() {
        surface._markedRange = NSRange(location: 0, length: 5)
        surface._selectedRange = NSRange(location: 5, length: 0)
        surface._markedRange = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 0, length: 0))
    }
}
