import agtermCore
import AppKit
import SwiftUI

/// Blends the window title bar with the terminal (the title text itself is set by
/// SwiftUI's `.navigationTitle`/`.navigationSubtitle`). The probe's `window` is nil at
/// make time, so the blend is applied from `viewDidMoveToWindow` (window attachment) and
/// re-applied on every `titleToken` change (session switch) and on the window key/
/// fullscreen transitions where AppKit rebuilds the titlebar subviews.
///
/// It also carries the per-window plumbing: it sets the frame autosave name, reports
/// frontmost (key/main) and close (`willClose`) to the `WindowLibrary`, and registers the
/// `NSWindow` in `WindowRegistry` for dedup/raise.
struct WindowAccessor: NSViewRepresentable {
    /// Changes when the active session changes, so `updateNSView` re-runs the blend.
    let titleToken: String
    let windowID: WindowInfo.ID
    let library: WindowLibrary
    let store: AppStore

    func makeNSView(context _: Context) -> TitleProbeView {
        TitleProbeView(windowID: windowID, library: library, store: store)
    }

    func updateNSView(_ nsView: TitleProbeView, context _: Context) {
        nsView.reapplyBlend(title: titleToken)
    }

    final class TitleProbeView: NSView {
        private let windowID: WindowInfo.ID
        private let library: WindowLibrary
        private let store: AppStore

        /// Observer tokens for window key/fullscreen transitions, after which AppKit
        /// rebuilds the titlebar subviews and the blend must be re-applied.
        nonisolated(unsafe) private var titlebarObservers: [NSObjectProtocol] = []

        /// One-shot guard so the saved frame is applied exactly once per window attach.
        private var frameRestored = false

        /// The confirm-before-close delegate proxy, owned here (NSWindow.delegate is weak).
        private var closeProxy: WindowCloseDelegateProxy?

        init(windowID: WindowInfo.ID, library: WindowLibrary, store: AppStore) {
            self.windowID = windowID
            self.library = library
            self.store = store
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// The current window title ("session — window"). Set on the OS window (for the window menu
        /// and XCUITest title-matching) but kept visually hidden via titleVisibility, since our custom
        /// header renders the visible title.
        private var latestTitle = ""

        /// Re-apply the blend with the latest title (called from `updateNSView` on a session switch).
        func reapplyBlend(title: String) {
            latestTitle = title
            if let window { applyTitlebarBlend(window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
            titlebarObservers.removeAll()
            guard let window else { return }
            // the app owns its window set (WindowLibrary + windows.json reopen-all); SwiftUI's own
            // WindowGroup restoration only fights that by re-creating empty stray windows from the
            // remembered window count (shared by bundle id, not isolated). Opt every real window fully
            // out of AppKit/SwiftUI restoration so that remembered set never grows.
            window.isRestorable = false
            window.restorationClass = nil
            window.disableSnapshotRestoration()
            window.invalidateRestorableState()
            frameRestored = false
            // per-window geometry keyed by OUR window id. SwiftUI's WindowGroup autosaves frames under
            // its own index-based name ("terminal-AppWindow-N") and OVERRIDES any setFrameAutosaveName
            // we set — and that index doesn't track a window's identity across an in-session
            // close/reopen, so the reopened window lands on the wrong/default slot. Instead we persist
            // the frame ourselves on close (keyed by the stable window UUID, in UserDefaults) and
            // re-apply it here AFTER SwiftUI's initial .defaultSize pass — on window-key plus a short
            // delayed fallback — one-shot via `frameRestored`.
            let frameKeyToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                DispatchQueue.main.async {
                    guard let self, let window, self.window === window else { return }
                    self.restoreSavedFrame(window)
                }
            }
            titlebarObservers.append(frameKeyToken)
            // fallback on the next run-loop tick (not a fixed delay) so the saved frame snaps in as soon
            // as SwiftUI's initial sizing pass is done, minimizing the visible default-then-resize.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.restoreSavedFrame(window)
            }
            // attach-race guard: if a window.close dropped this window's store while it was still
            // attaching (window.new immediately followed by window.close), it's a zombie — close it
            // rather than register and leave an orphaned on-screen window for a now-closed id.
            guard library.isOpen(windowID) else {
                DispatchQueue.main.async { [weak window] in
                    window?.orderOut(nil)
                    window?.close()
                }
                return
            }
            // register the NSWindow so the app can raise an already-open window for this id (dedup)
            // instead of spawning a second; install the confirm-before-close delegate proxy.
            WindowRegistry.shared.register(windowID, window: window)
            ensureCloseProxy(on: window)
            applyTitlebarBlend(window)
            // the private titlebar subviews may not exist yet / get rebuilt after layout — re-apply the
            // blend and re-assert the close proxy (SwiftUI may re-own the delegate after attach).
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.ensureCloseProxy(on: window)
                self.applyTitlebarBlend(window)
            }
            // AppKit rebuilds the titlebar subviews and re-renders the sidebar Liquid Glass on
            // key/main/fullscreen transitions (becomeKey fires right at launch), undoing the cleared
            // titlebar layer and the glass tint — re-apply on every transition, including resign so a
            // background window keeps the terminal tint instead of the lighter default glass. Only
            // becomeKey/becomeMain mean this window became frontmost; resign/fullscreen do not.
            let frontmostNames: Set<NSNotification.Name> = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                         NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                // the observer block is @Sendable, so it must not touch main-actor state
                // directly; hop through DispatchQueue.main like the re-applies above.
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [windowID] notification in
                    let becameFrontmost = frontmostNames.contains(notification.name)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let window = self.window else { return }
                        self.applyTitlebarBlend(window)
                        if becameFrontmost { self.reportFrontmost(windowID) }
                    }
                }
                titlebarObservers.append(token)
            }
            // report close: tear down this window's surfaces, then mark it closed in the library.
            // capture library/store/id directly (NOT through `self`) — the view is being deallocated
            // as the window closes, so a `[weak self]` hop would no-op and the index would never update.
            let closeToken = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [library, store, windowID, weak window] _ in
                MainActor.assumeIsolated {
                    // persist this window's final frame (keyed by its id) so an in-session reopen — or
                    // a restart — restores its size/position. SwiftUI's own index-based autosave can't.
                    if let window {
                        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: TitleProbeView.frameKey(windowID))
                    }
                    WindowRegistry.shared.unregister(windowID)
                    store.finalizeAllPendingCloses()
                    // flush cwd drift since the last structural mutation before dropping the store —
                    // AppStore doesn't save on a live `cd`, so a closed-then-reopened window would
                    // otherwise load a stale snapshot. Skip it when the window is no longer open in the
                    // library (a delete already dropped the store + removed the per-window file, so a
                    // save here would resurrect an orphan file).
                    if library.isOpen(windowID) { store.save() }
                    for session in store.workspaces.flatMap(\.sessions) {
                        session.surface?.teardown()
                        session.splitSurface?.teardown()
                        session.overlaySurface?.teardown()
                        session.scratchSurface?.teardown()
                    }
                    library.closeWindow(windowID)
                    // closing a window drops its (unobserved) store, so the Dock badge's observation
                    // tracking won't fire — refresh it explicitly so the unseen total drops this window's.
                    // guard on isTerminating: on quit the willClose fires after applicationWillTerminate's
                    // clear(), and closeWindow no-ops (stores stay loaded), so an unguarded refresh would
                    // recompute the still-positive total and re-pin the badge clear() just zeroed.
                    if !library.isTerminating { DockBadgeController.shared.refresh() }
                }
            }
            titlebarObservers.append(closeToken)
            // a settings theme change updates GhosttyApp.terminalBackgroundColor; re-apply the
            // blend so the title bar and the (transparent) sidebar pick up the new window color
            // live, not just when the window next re-keys.
            let appearanceToken = NotificationCenter.default.addObserver(forName: .agtermAppearanceChanged, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    self.applyTitlebarBlend(window)
                }
            }
            titlebarObservers.append(appearanceToken)
            // a window restored in a miniaturized state isn't on-screen, so a fresh
            // launch shows nothing and UI-test automation has nothing to hit. bring it
            // forward un-minimized; re-assert next tick because state restoration can
            // re-apply the miniaturized state right after the view attaches.
            bringForward(window)
            DispatchQueue.main.async { [weak self] in self?.bringForward(window) }
            scheduleUITestWindowForward(window)
            // the window may already be key here: a reopened/raised window can become key DURING
            // creation, before these observers were installed, so that initial didBecomeKey was missed
            // (and bringForward above is then a no-op). Report frontmost explicitly so the palette /
            // session switcher route to THIS window immediately, not the previously-frontmost one.
            if window.isKeyWindow || window.isMainWindow { reportFrontmost(windowID) }
        }

        deinit {
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Record this window as the frontmost in the library and persist the index. A no-op when this
        /// window is already frontmost, so the paired `didBecomeKey`/`didBecomeMain` (and a re-key of
        /// the same window) collapse to a single write instead of a per-focus-change write-storm.
        @MainActor private func reportFrontmost(_ id: WindowInfo.ID) {
            guard library.frontmostWindowID != id else { return }
            library.frontmostWindowID = id
            library.saveIndex()
            // the active-window change is async; let the control server refresh its cached window list
            // so a `window.list` poll sees the new `active` flag without waiting for the next command.
            NotificationCenter.default.post(name: .agtermWindowFrontmostChanged, object: nil)
        }

        private func bringForward(_ window: NSWindow) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }

        /// UserDefaults key for this window's saved frame, keyed by the stable window UUID (NOT
        /// SwiftUI's index-based autosave name, which it overrides and which doesn't track identity).
        static func frameKey(_ id: WindowInfo.ID) -> String { "agterm-frame-\(id.uuidString)" }

        /// Applies the saved frame for this window id, once. Deferred (window-key / next tick) so
        /// SwiftUI's initial `.defaultSize` pass has run and won't clobber the restored geometry.
        private func restoreSavedFrame(_ window: NSWindow) {
            guard !frameRestored else { return }
            frameRestored = true
            guard let saved = UserDefaults.standard.string(forKey: Self.frameKey(windowID)) else { return }
            let frame = NSRectFromString(saved)
            guard frame.width > 0, frame.height > 0 else { return }
            window.setFrame(Self.constrainedRestoredFrame(frame, for: window), display: true)
        }

        /// Normalize a persisted frame before restore. A saved `NSRect` may come from a display that is
        /// no longer attached; applying it directly can put the relaunched window entirely off-screen.
        /// Keep the saved size/position when possible, but fully contain it on a current screen.
        private static func constrainedRestoredFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
            let screens = NSScreen.screens
            guard !screens.isEmpty, let fallback = window.screen ?? NSScreen.main ?? screens.first else { return frame }
            let displayFrames = screens.map { WindowGeometry.Rect($0.frame) }
            let fallbackIndex = screens.firstIndex(of: fallback) ?? 0
            let displayIndex = WindowGeometry.bestDisplayIndex(for: WindowGeometry.Rect(frame), among: displayFrames) ?? fallbackIndex
            let displayFrame = WindowGeometry.Rect(screens[displayIndex].visibleFrame)
            let constrained = WindowGeometry.constrain(frame: WindowGeometry.Rect(frame),
                                                       min: WindowGeometry.Size(window.minSize),
                                                       displayFrame: displayFrame)
            return constrained.nsRect
        }

        /// Installs (or re-asserts) the confirm-before-close proxy as the window's delegate, chaining to
        /// whatever delegate SwiftUI set. No-op when it's already the delegate.
        private func ensureCloseProxy(on window: NSWindow) {
            if closeProxy == nil {
                closeProxy = WindowCloseDelegateProxy(windowID: windowID, library: library, store: store)
            }
            guard let closeProxy else { return }
            if (window.delegate as AnyObject?) !== closeProxy {
                closeProxy.forwardingDelegate = window.delegate
                window.delegate = closeProxy
            }
        }

        /// Re-assert the window forward under XCUITest: the FB11763863 reopen can present it slightly
        /// after the view attaches, so keep ordering it front for a short schedule.
        private func scheduleUITestWindowForward(_ window: NSWindow) {
            guard ContentView.isUITestLaunch else { return }
            let delays: [TimeInterval] = [0, 0.05, 0.15, 0.35, 0.7, 0.95]
            for delay in delays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    self.bringForwardForUITests(window)
                }
            }
        }

        /// One-shot latch so the per-window retry presents this window at most once.
        private var didPresentForUITests = false
        private func bringForwardForUITests(_ window: NSWindow) {
            // present a window that isn't on screen yet (FB11763863: created minimized/background), then
            // latch off. Re-fronting on later ticks (or a momentary !isVisible during a re-render) would
            // fight a deliberate window.select and oscillate the key window, flapping the "active" flag.
            guard !didPresentForUITests, window.isMiniaturized || !window.isVisible else { return }
            NSApp.unhide(nil)
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            didPresentForUITests = true
        }

        private func applyTitlebarBlend(_ window: NSWindow) {
            // set the OS window title (kept hidden via titleVisibility in the sync) so the window menu
            // and XCUITest title-matching see it, even though our custom header shows the visible title.
            window.title = latestTitle
            let background = GhosttyApp.shared.terminalBackgroundColor
                ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1)
            WindowAppearance.sync(window: window, background: background,
                                  chrome: .init(opacity: GhosttyApp.shared.windowOpacity,
                                                blurRadius: GhosttyApp.shared.windowBlurRadius,
                                                toolbarMode: GhosttyApp.shared.toolbarMode))
        }
    }
}

// CoreGraphics <-> host-free WindowGeometry conversions for restore-frame clamping. The arithmetic lives
// in agtermCore so display-selection and off-screen restore edge cases stay unit-testable.
private extension WindowGeometry.Size {
    init(_ cg: CGSize) { self.init(width: Double(cg.width), height: Double(cg.height)) }
}

private extension WindowGeometry.Rect {
    init(_ cg: CGRect) {
        self.init(origin: WindowGeometry.Point(x: Double(cg.origin.x), y: Double(cg.origin.y)),
                  size: WindowGeometry.Size(cg.size))
    }

    var nsRect: NSRect {
        NSRect(x: CGFloat(origin.x), y: CGFloat(origin.y),
               width: CGFloat(size.width), height: CGFloat(size.height))
    }
}

/// Forwarding `NSWindowDelegate` that adds a confirm-before-close for a window with running sessions,
/// forwarding every other delegate call to whatever delegate SwiftUI installed. Owned strongly by
/// `TitleProbeView` (`NSWindow.delegate` is weak). Intercepts USER-driven closes (red button, File ▸
/// Close); the programmatic `WindowRegistry.close` uses `window.close()` and skips `windowShouldClose`,
/// so Delete Window / agtermctl don't double-prompt.
@MainActor
private final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var forwardingDelegate: NSObjectProtocol?
    private let windowID: WindowInfo.ID
    private let library: WindowLibrary
    private let store: AppStore
    private var sheetOpen = false

    init(windowID: WindowInfo.ID, library: WindowLibrary, store: AppStore) {
        self.windowID = windowID
        self.library = library
        self.store = store
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let count = store.workspaces.reduce(0) { $0 + $1.sessions.count }
        guard count > 0 else { return forwardedShouldClose(sender) }
        guard !sheetOpen else { return false }
        sheetOpen = true
        let name = library.windows.first { $0.id == windowID }?.name ?? "window"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \u{201C}\(name)\u{201D}?"
        alert.informativeText = "This ends \(count) running session\(count == 1 ? "" : "s"). The window can be reopened from File ▸ Open Window."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self, let sender else { return }
            MainActor.assumeIsolated {
                self.sheetOpen = false
                guard response == .alertFirstButtonReturn else { return }
                // force-close: close() doesn't re-enter windowShouldClose (no re-prompt) but still runs
                // the willClose teardown + library mark-closed. The user already confirmed.
                sender.close()
            }
        }
        return false
    }

    private func forwardedShouldClose(_ sender: NSWindow) -> Bool {
        (forwardingDelegate as? NSWindowDelegate)?.windowShouldClose?(sender) ?? true
    }

    // forward every other NSWindowDelegate selector to SwiftUI's delegate so its window bookkeeping
    // (willClose, didResize, …) still runs. Called by the ObjC runtime; reads the weak forward target.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardingDelegate?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        forwardingDelegate?.responds(to: selector) == true ? forwardingDelegate : super.forwardingTarget(for: selector)
    }
}
