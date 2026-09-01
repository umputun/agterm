import XCTest
@testable import agterm
@testable import agtermCore

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

    func testPaneRoleMutationUpdatesLiveRoleWithoutChangingToken() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                     env: ["AGTERM_PANE_ID": "stable-token"])
        view.setPaneRole(.split)
        view.setPaneRole(.split)
        XCTAssertTrue(view.isSplitPane)
        XCTAssertEqual(view.paneToken, "stable-token")
        view.setPaneRole(.primary)
        view.setPaneRole(.primary)
        XCTAssertFalse(view.isSplitPane)
        XCTAssertEqual(view.paneToken, "stable-token")
    }

    func testPaneFocusDecisionUsesTheSurfaceLiveRole() {
        surface.setPaneRole(.split)
        XCTAssertEqual(agtermApp.focusedSplitState(true, surface: surface), true)
        XCTAssertNil(agtermApp.focusedSplitState(false, surface: surface))
        surface.setPaneRole(.primary)
        XCTAssertEqual(agtermApp.focusedSplitState(true, surface: surface), false)
    }

    func testFontPersistenceUsesTheSurfaceLiveRole() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(persistence: PersistenceStore(directory: directory))
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/tmp")!

        surface.setPaneRole(.split)
        agtermApp.persistFontSize(17, from: surface, store: store, sessionID: session.id)
        XCTAssertNil(session.fontSize)

        surface.setPaneRole(.primary)
        agtermApp.persistFontSize(17, from: surface, store: store, sessionID: session.id)
        XCTAssertEqual(session.fontSize, 17)
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

    // MARK: - launch seed

    func testResolvingTheDeferredSeedRunsOnceAndLatchesTheValues() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        var resolves = 0
        view.launchSeed = LaunchSeedProvider(shouldPace: true) { _ in
            resolves += 1
            return LaunchSeed(command: nil, initialInput: "npm run dev\n", waitAfterCommand: false)
        }

        let first = view.resolveLaunchSeed()
        let second = view.resolveLaunchSeed()

        XCTAssertEqual(resolves, 1, "a retried creation must not consume the pending slots a second time")
        XCTAssertEqual(first, LaunchSeed(command: nil, initialInput: "npm run dev\n", waitAfterCommand: false))
        XCTAssertEqual(second, first)
        XCTAssertNil(view.launchSeed)
    }

    func testResolvingPassesTheSurfacesLivePaneRole() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        view.setPaneRole(.split)
        var asked: StatusPane?
        view.launchSeed = LaunchSeedProvider(shouldPace: true) { pane in
            asked = pane
            return LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        }

        view.resolveLaunchSeed()

        XCTAssertEqual(asked, .right)
    }

    func testAViewWithoutAProviderKeepsItsConstructorValues() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                      command: "revdiff", waitAfterCommand: true)

        XCTAssertEqual(view.resolveLaunchSeed(),
                       LaunchSeed(command: "revdiff", initialInput: nil, waitAfterCommand: true))
        XCTAssertNil(view.launchSeed)
    }

    func testTeardownDropsTheUnresolvedProvider() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        view.launchSeed = LaunchSeedProvider(shouldPace: true) { _ in
            XCTFail("a torn-down surface must not consume its pending slots")
            return LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        }

        view.destroySurface()

        XCTAssertNil(view.launchSeed)
    }

    /// A provider holding its session strongly would close the `Session -> surface -> provider -> Session`
    /// cycle and leak every pane destroyed before it spawned.
    func testAViewDestroyedBeforeResolutionDeallocates() {
        let session = Session(initialCwd: "/tmp")
        weak var released: GhosttySurfaceView?
        autoreleasepool {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            view.session = session
            view.launchSeed = LaunchSeedProvider.pane(
                session: session, pane: .left, disposition: .ordinary,
                policy: .init(restoreEnabled: true, denylist: [], runningNames: nil))
            session.surface = view
            released = view
            session.surface = nil
        }

        XCTAssertNil(released)
    }

    // MARK: - spawn permit

    /// Every paced pane in these tests is DENIED its permit: a granted one at a real size would spawn the
    /// user's login shell inside the test host, which is why the granted side is driven through
    /// `requestSpawnPermit()` rather than through `createSurface()`.
    private func makeQueuedPane(size: NSSize = NSSize(width: 240, height: 160))
        -> (view: GhosttySurfaceView, pacer: SpawnPacer, key: UUID) {
        let pacer = SpawnPacer()
        let key = UUID()
        pacer.arm(order: [key], burst: [])
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        view.useSpawnPacer(pacer, key: key)
        view.launchSeed = LaunchSeedProvider(shouldPace: true) { _ in
            XCTFail("a queued pane must not consume its seed before the permit")
            return LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        }
        view.setFrameSize(size)
        return (view, pacer, key)
    }

    private func assertStillQueued(_ view: GhosttySurfaceView, _ path: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(view.isRealized, "\(path) spawned a surface without a permit", file: file, line: line)
        XCTAssertTrue(view.awaitingSpawnPermit, "\(path) never reached the gate", file: file, line: line)
        XCTAssertNotNil(view.launchSeed, "\(path) consumed the pending slots before the permit",
                        file: file, line: line)
    }

    func testADeniedPaneCreatesNoSurfaceAndKeepsItsSeedArmed() {
        let paned = makeQueuedPane()

        paned.view.createSurface()

        assertStillQueued(paned.view, "updateNSView")
    }

    func testTheWindowAttachEntryPathReachesTheGate() {
        let paned = makeQueuedPane()

        content.addSubview(paned.view)

        assertStillQueued(paned.view, "viewDidMoveToWindow")
        paned.view.removeFromSuperview()
    }

    func testTheDeferredSizeRetryEntryPathReachesTheGate() {
        let paned = makeQueuedPane(size: .zero)

        paned.view.createSurface()
        XCTAssertFalse(paned.view.awaitingSpawnPermit, "a zero-size pane asks for nothing")
        paned.view.setFrameSize(NSSize(width: 240, height: 160))

        assertStillQueued(paned.view, "setFrameSize")
    }

    func testTheDisplayWakeRetryEntryPathReachesTheGate() async throws {
        let paned = makeQueuedPane()

        NotificationCenter.default.post(name: .agtermScreensDidWake, object: nil)

        try await waitUntil("the wake retry reaches the gate") { paned.view.awaitingSpawnPermit }
        assertStillQueued(paned.view, "retryCreationAfterWake")
    }

    /// A pane deferred on a zero size must not hold a token: the queue would spend an interval on a view
    /// that still cannot spawn, and the token would be waiting for it when a later layout burst arrives.
    func testAZeroSizedPaneAsksForNoPermit() {
        let paned = makeQueuedPane(size: .zero)
        var granted: [UUID] = []
        paned.pacer.onGrant = { granted.append($0) }

        paned.view.createSurface()
        paned.pacer.expedite(paned.key)

        XCTAssertFalse(paned.view.awaitingSpawnPermit)
        XCTAssertTrue(granted.isEmpty, "expedite grants a READY key, so a token means the view had requested")
    }

    func testAGrantedKeyPassesTheGate() {
        let paned = makeQueuedPane()

        XCTAssertFalse(paned.view.requestSpawnPermit())
        XCTAssertTrue(paned.view.awaitingSpawnPermit)
        paned.pacer.expedite(paned.key)

        XCTAssertTrue(paned.view.requestSpawnPermit())
        XCTAssertFalse(paned.view.awaitingSpawnPermit)
    }

    func testAnUnarmedPacerGrantsOnRequest() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        view.useSpawnPacer(SpawnPacer(), key: UUID())

        XCTAssertTrue(view.requestSpawnPermit())
        XCTAssertFalse(view.awaitingSpawnPermit)
    }

    func testAPaneOutsideTheLaunchQueueNeedsNoPermit() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())

        XCTAssertTrue(view.requestSpawnPermit())
    }

    func testTeardownLeavesTheQueueAndTheLaterGrantDoesNothing() {
        let paned = makeQueuedPane()
        paned.view.createSurface()

        paned.view.destroySurface()

        XCTAssertTrue(paned.pacer.isPassthrough, "a torn-down pane must not hold the rest of the queue")
        paned.view.unregisterDraggedTypes()
        paned.view.createSurface()
        XCTAssertTrue(paned.view.registeredDraggedTypes.isEmpty,
                      "a grant reaching a torn-down pane must not re-enter creation")
    }

    /// The safety net for a queued pane dropped without a teardown: `deinit` is nonisolated, so it schedules
    /// a key-only cancellation instead of touching the pacer inline.
    func testDeinitCancelsTheQueuedPermit() async throws {
        let pacer = SpawnPacer()
        let key = UUID()
        pacer.arm(order: [key], burst: [])
        autoreleasepool {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            view.useSpawnPacer(pacer, key: key)
            _ = view.requestSpawnPermit()
        }
        XCTAssertFalse(pacer.isPassthrough)

        try await waitUntil("deinit cancels the permit") { pacer.isPassthrough }
    }

    // MARK: - selection preemption

    private func queuedPair() -> (pacer: SpawnPacer, keys: [UUID], views: [GhosttySurfaceView]) {
        let pacer = SpawnPacer()
        let keys = [UUID(), UUID()]
        pacer.arm(order: keys, burst: [])
        let views = keys.map { key -> GhosttySurfaceView in
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            view.useSpawnPacer(pacer, key: key)
            XCTAssertFalse(view.requestSpawnPermit())
            return view
        }
        return (pacer, keys, views)
    }

    func testSelectingAQueuedPaneGrantsItBeforeTheQueueReachesIt() {
        let pair = queuedPair()

        pair.views[1].deckVisible = true

        XCTAssertTrue(pair.views[1].requestSpawnPermit(), "the selected pane jumps the queue")
        XCTAssertFalse(pair.views[0].requestSpawnPermit(), "the head of the queue still waits its interval")
    }

    /// The deck and the zoom host both set `deckVisible` before the first `createSurface`, so a selected pane
    /// is granted on that first request rather than one interval later.
    func testAPaneActiveBeforeItsFirstRequestIsGrantedOnThatRequest() {
        let pacer = SpawnPacer()
        let key = UUID()
        pacer.arm(order: [UUID(), key], burst: [])
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        view.useSpawnPacer(pacer, key: key)

        view.deckVisible = true

        XCTAssertTrue(view.requestSpawnPermit())
        XCTAssertFalse(view.awaitingSpawnPermit)
    }

    func testSelectingAPaneTwiceMintsOneToken() {
        let pair = queuedPair()
        var granted: [UUID] = []
        pair.pacer.onGrant = { granted.append($0) }

        pair.views[0].deckVisible = true
        pair.views[0].deckVisible = true

        XCTAssertEqual(granted, [pair.keys[0]])
        XCTAssertFalse(pair.views[1].requestSpawnPermit(), "a repeated selection must not release the next pane")
    }

    /// Both panes of a shown split are on screen, so selecting the session brings both up, whichever half
    /// holds split focus.
    func testSelectingAShownSplitBringsUpBothPanes() {
        let pair = queuedPair()

        pair.views[0].deckVisible = true
        pair.views[1].deckVisible = true

        XCTAssertTrue(pair.views[0].requestSpawnPermit())
        XCTAssertTrue(pair.views[1].requestSpawnPermit())
    }

    func testFocusAloneExpeditesNothing() {
        let pair = queuedPair()

        pair.views[1].deckActive = true

        XCTAssertFalse(pair.views[1].requestSpawnPermit(), "focus is not visibility")
    }

    func testAnUnpacedPaneIgnoresSelection() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())

        view.deckVisible = true

        XCTAssertTrue(view.requestSpawnPermit())
    }

    func testPrioritizeReleasesNothing() {
        let pair = queuedPair()
        var granted: [UUID] = []
        pair.pacer.onGrant = { granted.append($0) }

        GhosttySurfaceView.prioritizeSpawn([pair.views[1], pair.views[0]])

        XCTAssertTrue(granted.isEmpty, "prioritize reorders; only the timer or an expedite grants")
        XCTAssertFalse(pair.views[1].requestSpawnPermit())
    }

    func testPrioritizeSkipsUnpacedViews() {
        let pair = queuedPair()
        let plain = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())

        GhosttySurfaceView.prioritizeSpawn([plain])
        GhosttySurfaceView.prioritizeSpawn([plain, pair.views[1]])

        XCTAssertTrue(plain.requestSpawnPermit())
        XCTAssertFalse(pair.views[1].requestSpawnPermit(), "an unpaced view never picks a pacer for the rest")
    }
}
