import XCTest
@testable import agterm

/// Content view whose hit resolution the test supplies directly, standing in for the real window
/// hierarchy: `ownsPointer` only asks who owns a point, so the geometry that would produce the answer is
/// beside the point here.
private final class StubContentView: NSView {
    var hitResult: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? { hitResult }
}

/// Pins the chrome-versus-surface split that keeps the resize cursor over the dividers (issue #324).
/// Returning true for chrome puts the flicker back; returning false for a sibling pane silences the
/// visible terminal's own cursor instead. Neither shows up in any other test. Also carries the surface's
/// other invisible contracts: the `viewOnly` refusal the dashboard and the HUD both rest on, the renderer
/// visibility gate, and the temp files teardown owns.
@MainActor
final class GhosttySurfaceViewTrackingTests: XCTestCase {
    private var window: NSWindow!
    private var content: StubContentView!
    private var surface: GhosttySurfaceView!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            content = StubContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            window.contentView = content
            // both surfaces stay at their zero init frame, so `viewDidMoveToWindow` parks in
            // `pendingSurfaceCreation` instead of spawning a libghostty surface and a shell.
            surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            content.addSubview(surface)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            surface.removeFromSuperview()
            surface = nil
            window.orderOut(nil)
            window = nil
            content = nil
        }
        try await super.tearDown()
    }

    func testDeclinesWhenChromeOwnsThePoint() {
        content.hitResult = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 200))
        XCTAssertFalse(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
    }

    func testOwnsThePointWhenTheHitIsItself() {
        content.hitResult = surface
        XCTAssertTrue(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
    }

    func testOwnsThePointWhenTheHitIsItsOwnDescendant() {
        let child = NSView(frame: .zero)
        surface.addSubview(child)
        content.hitResult = child
        XCTAssertTrue(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
    }

    /// A split's other pane is on screen too, so owning the point keeps its own cursor writer alive.
    func testOwnsThePointWhenTheHitIsASiblingSurface() {
        let sibling = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        content.addSubview(sibling)
        content.hitResult = sibling
        XCTAssertTrue(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
        sibling.removeFromSuperview()
    }

    func testOwnsThePointWhenNothingIsHit() {
        content.hitResult = nil
        XCTAssertTrue(surface.ownsPointer(at: NSPoint(x: 10, y: 100)))
    }

    /// Arrange `surface` inside a real split, leaving its frame at zero so no libghostty surface is created.
    private func arrangeInSplit() -> NSSplitView {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        split.isVertical = true
        for _ in 0..<2 { split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 200))) }
        content.addSubview(split)
        split.setPosition(160, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        surface.removeFromSuperview()
        split.arrangedSubviews[0].addSubview(surface)
        return split
    }

    /// The divider outranks the window-down hit, which reaches whichever session's split the deck stacked
    /// last rather than this pane's own.
    func testDeclinesOverItsOwnSplitDividerEvenWhenTheHitIsItself() {
        let split = arrangeInSplit()
        content.hitResult = surface
        XCTAssertFalse(surface.ownsPointer(at: NSPoint(x: 160 + split.dividerThickness / 2, y: 100)))
    }

    func testOwnsThePointInsideItsOwnSplitAwayFromTheDivider() {
        _ = arrangeInSplit()
        content.hitResult = surface
        XCTAssertTrue(surface.ownsPointer(at: NSPoint(x: 40, y: 100)))
    }

    func testOwnsThePointWhenDetachedFromAnyWindow() {
        let detached = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        XCTAssertTrue(detached.ownsPointer(at: NSPoint(x: 10, y: 100)))
        XCTAssertTrue(detached.ownsPointer())
    }

    // MARK: - view-only

    /// The HUD panel's passivity and the dashboard cell's both rest on THIS, not on `.allowsHitTesting`,
    /// which AppKit routes clicks past: a hit reaching `mouseDown` makes the surface first responder and
    /// takes every keystroke with it.
    func testViewOnlyRefusesBothHitsAndFirstResponder() {
        // detached and sized: `hitTest` needs a real frame, and no window means no libghostty surface
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        view.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        let inside = NSPoint(x: 40, y: 30)

        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertNotNil(view.hitTest(inside))

        view.viewOnly = true

        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertNil(view.hitTest(inside), "a view-only surface must let the click through instead of taking it")
    }

    func testRendererVisibilityRequiresAnOnScreenHost() {
        surface.wantsLayer = true
        surface.layer?.contents = NSColor.red.cgColor
        XCTAssertTrue(surface.showsOnScreen)
        surface.deckOnScreen = false
        XCTAssertFalse(surface.showsOnScreen)
        XCTAssertNotNil(surface.rendererVisibilityTask)
        surface.updateRendererVisibility(delayHide: false)
        XCTAssertNil(surface.rendererVisibilityTask)
        surface.deckOnScreen = true
        surface.removeFromSuperview()
        XCTAssertFalse(surface.showsOnScreen)
    }

    func testHiddenJanitorSweepsWhileHiddenAndRetiresOnReveal() async throws {
        surface.wantsLayer = true
        surface.layer?.contents = NSColor.red.cgColor
        surface.rendererVisible = false
        surface.startHiddenJanitor(interval: 20_000_000)
        XCTAssertNotNil(surface.hiddenJanitorTask)
        try await waitUntil("retained frame swept") { self.surface.layer?.contents == nil }
        surface.rendererVisible = true
        try await waitUntil("janitor retires after reveal") { self.surface.hiddenJanitorTask == nil }
    }

    func testDestroySurfaceCancelsTheHiddenJanitor() {
        surface.rendererVisible = false
        surface.startHiddenJanitor()
        XCTAssertNotNil(surface.hiddenJanitorTask)
        surface.destroySurface()
        XCTAssertNil(surface.hiddenJanitorTask)
    }

    func testDeferredHideLandsAfterTheFirstPresent() async throws {
        surface.wantsLayer = true
        surface.deckOnScreen = false
        surface.updateRendererVisibility(
            delayHide: false, grace: 10_000_000_000, presentPoll: 10_000_000, presentTimeout: 5_000_000_000
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(surface.rendererVisibilityTask)
        surface.layer?.contents = NSColor.red.cgColor
        try await waitUntil("hide lands after first present") { self.surface.rendererVisibilityTask == nil }
        XCTAssertEqual(surface.layer?.needsDisplayOnBoundsChange, false)
    }

    func testDeferredHideExpiresForANeverPaintedPane() async throws {
        surface.wantsLayer = true
        surface.deckOnScreen = false
        surface.updateRendererVisibility(delayHide: false, presentPoll: 10_000_000, presentTimeout: 50_000_000)
        XCTAssertNotNil(surface.rendererVisibilityTask)
        try await waitUntil("expiry hides the pane") { self.surface.rendererVisibilityTask == nil }
        XCTAssertEqual(surface.layer?.needsDisplayOnBoundsChange, false)
    }

    func testRevealCancelsTheDeferredHideAndRestoresBoundsRedraw() {
        surface.wantsLayer = true
        surface.deckOnScreen = false
        surface.updateRendererVisibility(delayHide: false, presentPoll: 10_000_000, presentTimeout: 5_000_000_000)
        XCTAssertNotNil(surface.rendererVisibilityTask)
        surface.deckOnScreen = true
        XCTAssertNil(surface.rendererVisibilityTask)
        XCTAssertEqual(surface.layer?.needsDisplayOnBoundsChange, true)
    }

    func testAlreadyPaintedPaneHidesWithoutDeferral() {
        surface.wantsLayer = true
        surface.layer?.needsDisplayOnBoundsChange = true
        surface.layer?.contents = NSColor.red.cgColor
        surface.deckOnScreen = false
        surface.updateRendererVisibility(delayHide: false)
        XCTAssertNil(surface.rendererVisibilityTask)
        XCTAssertEqual(surface.layer?.needsDisplayOnBoundsChange, false)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: - teardown

    /// The HUD's body file has no status to read, so deleting it IS the teardown — and it is also how a
    /// helper whose app never ran teardown learns to stop. Every path through `destroySurface` owes it.
    func testTeardownRemovesTheHudBodyFile() throws {
        let body = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-hud-teardown-\(UUID().uuidString).txt")
        try "40 3 0 0\nworking\n".write(to: body, atomically: true, encoding: .utf8)
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        view.hudBodyFile = body.path

        view.destroySurface()

        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path),
                       "a torn-down hud surface must not leave its painter a file to keep reading")
        XCTAssertNil(view.hudBodyFile)
    }

    /// #443: libghostty's layer holds a display callback into the renderer `destroySurface` frees, so the
    /// next CoreAnimation display of that layer aborts the process on a corrupt lock.
    func testTeardownDropsTheLayerLibghosttyInstalled() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        let stale = CALayer()
        stale.contentsScale = 3
        view.layer = stale

        view.destroySurface()

        XCTAssertFalse(view.layer === stale, "a torn-down surface must not keep the layer libghostty installed")
        XCTAssertEqual(view.layer?.contentsScale, 3, "the replacement carries the last frame, so nothing blanks")
    }
}
