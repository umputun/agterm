import GhosttyKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class GhosttySurfaceViewInputTests: XCTestCase {
    private var savedOpener = LinkOpener()

    private final class Followed {
        var opened: [URL] = []
        var revealed: [URL] = []
        var overlaid: [(URL, UUID, Int?)] = []
    }

    private func recordLinks(mode: LinkOpenMode, overlayOpens: Bool) -> Followed {
        let followed = Followed()
        LinkOpener.shared.mode = { mode }
        LinkOpener.shared.open = { followed.opened.append($0) }
        LinkOpener.shared.reveal = { followed.revealed.append($0) }
        LinkOpener.shared.overlay = { url, session, percent in
            followed.overlaid.append((url, session, percent))
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
        pane.openLink(url.absoluteString, wantsBrowser: false)
        XCTAssertEqual(shown.overlaid.map(\.0), [url])
        XCTAssertEqual(shown.overlaid.map(\.1), [session.id])
        XCTAssertEqual(shown.overlaid.map(\.2), [nil])
        XCTAssertTrue(shown.opened.isEmpty)

        let sized = recordLinks(mode: .overlay75, overlayOpens: true)
        pane.openLink(url.absoluteString, wantsBrowser: false)
        XCTAssertEqual(sized.overlaid.map(\.2), [75])

        let refused = recordLinks(mode: .overlay, overlayOpens: false)
        pane.openLink(url.absoluteString, wantsBrowser: false)
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
        pane.openLink(web.absoluteString, wantsBrowser: false)
        XCTAssertEqual(browser.opened, [web])

        let overlay = recordLinks(mode: .overlay, overlayOpens: true)
        hud.openLink(web.absoluteString, wantsBrowser: false)
        pane.openLink(mail.absoluteString, wantsBrowser: false)
        pane.openLink("file:///tmp/x.md", wantsBrowser: false)
        pane.openLink("x-custom://run", wantsBrowser: false)
        XCTAssertEqual(overlay.opened, [web, mail])
        XCTAssertEqual(overlay.revealed, [URL(fileURLWithPath: "/tmp/x.md", isDirectory: false)])
        XCTAssertTrue(browser.overlaid.isEmpty && overlay.overlaid.isEmpty)
    }

    func testCommandShiftClickOnADetectedURLOpensTheBrowserInOverlayMode() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1")
        defer { fixture.close() }
        let url = try XCTUnwrap(URL(string: "https://example.com/pr/1"))

        let plain = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: .command)
        fixture.click(flags: .command)
        fixture.wait { !plain.overlaid.isEmpty }
        XCTAssertEqual(plain.overlaid.map(\.0), [url], fixture.geometry)
        XCTAssertTrue(plain.opened.isEmpty)

        let chord = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: [.command, .shift])
        fixture.click(flags: [.command, .shift])
        fixture.wait { !chord.opened.isEmpty }
        XCTAssertEqual(chord.opened, [url], fixture.geometry)
        XCTAssertTrue(chord.overlaid.isEmpty)
    }

    func testCommandShiftClickOnAnOSC8LinkOpensItsTargetInTheBrowser() throws {
        let fixture = try LinkClickFixture(printing: #"\033]8;;https://example.com/osc\033\\open the pull request\033]8;;\033\\"#)
        defer { fixture.close() }
        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: [.command, .shift])
        fixture.click(flags: [.command, .shift])
        fixture.wait { !shown.opened.isEmpty }
        XCTAssertEqual(shown.opened, [try XCTUnwrap(URL(string: "https://example.com/osc"))], fixture.geometry)
        XCTAssertTrue(shown.overlaid.isEmpty)
    }

    func testShiftPressedUnderAStillPointerKeepsTheLinkHovered() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1")
        defer { fixture.close() }
        _ = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: .command)
        fixture.wait { fixture.surface.mouseShape == GHOSTTY_MOUSE_SHAPE_POINTER }
        fixture.flagsChanged(keyCode: 56, flags: [.shift, .command])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(fixture.surface.mouseShape, GHOSTTY_MOUSE_SHAPE_POINTER, fixture.geometry)
    }

    func testCommandShiftClickOnAStillPointerWithoutAModifierChangeOpensTheBrowser() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1")
        defer { fixture.close() }
        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: [])
        fixture.click(flags: [.command, .shift])
        fixture.wait { !shown.opened.isEmpty }
        XCTAssertEqual(shown.opened, [try XCTUnwrap(URL(string: "https://example.com/pr/1"))], fixture.geometry)
    }

    func testCommandShiftClickUnderMouseCaptureFollowsTheOverlaySetting() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1", before: #"\033[?1000h"#)
        defer { fixture.close() }
        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.wait { fixture.surface.surface.map(ghostty_surface_mouse_captured) == true }
        fixture.move(flags: [.command, .shift])
        fixture.click(flags: [.command, .shift])
        fixture.wait { !shown.opened.isEmpty || !shown.overlaid.isEmpty }
        XCTAssertEqual(shown.overlaid.map(\.0), [try XCTUnwrap(URL(string: "https://example.com/pr/1"))], fixture.geometry)
        XCTAssertTrue(shown.opened.isEmpty)
    }

    func testCommandShiftClickInBrowserModeIsNotALinkClick() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1")
        defer { fixture.close() }
        let shown = recordLinks(mode: .browser, overlayOpens: true)
        fixture.move(flags: [.command, .shift])
        fixture.click(flags: [.command, .shift])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertTrue(shown.opened.isEmpty && shown.overlaid.isEmpty)
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

@MainActor
private final class LinkClickFixture {
    let surface: GhosttySurfaceView
    private let window: NSWindow
    private let session = Session(initialCwd: NSTemporaryDirectory())
    private var link = NSPoint.zero
    private let blank = NSPoint(x: 40, y: 20)

    init(printing text: String, before prefix: String = "") throws {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "printf '\(prefix)\(text)'; cat")
        surface.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(surface)
        surface.createSurface()
        XCTAssertTrue(surface.isRealized)
        let printed = { self.surface.readScreenText(all: false, lines: nil).map { $0.contains("example") || $0.contains("pull request") } == true }
        wait(printed)
        XCTAssertTrue(printed())
        let raw = try XCTUnwrap(surface.surface)
        let cell = try XCTUnwrap(surface.cellSize())
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(raw, &x, &y, &w, &h)
        link = NSPoint(x: x - 6 * cell.width, y: surface.bounds.height - (y - cell.height / 2))
        XCTAssertTrue(surface.bounds.contains(link))
        surface.session = session
    }

    var geometry: String {
        "link=\(link) cell=\(String(describing: surface.cellSize())) shape=\(surface.mouseShape.rawValue) "
            + "screen=<<\(surface.readScreenText(all: false, lines: nil) ?? "nil")>>"
    }

    func close() {
        surface.teardown()
        window.close()
    }

    func move(flags: NSEvent.ModifierFlags) {
        for point in [blank, link] { surface.mouseMoved(with: mouseEvent(.mouseMoved, at: point, flags: flags)) }
    }

    func click(flags: NSEvent.ModifierFlags) {
        surface.mouseDown(with: mouseEvent(.leftMouseDown, at: link, flags: flags))
        surface.mouseUp(with: mouseEvent(.leftMouseUp, at: link, flags: flags))
    }

    func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(with: .flagsChanged, location: link, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "",
                                     charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
        surface.flagsChanged(with: event!)
    }

    func wait(_ done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
