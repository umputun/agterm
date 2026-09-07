import XCTest
@testable import agterm
import agtermCore

@MainActor
final class GhosttySurfaceViewInputTests: XCTestCase {
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
        await MainActor.run { surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory()) }
    }

    override func tearDown() async throws {
        await MainActor.run { surface = nil }
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
