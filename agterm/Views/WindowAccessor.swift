import agtermCore
import AppKit
import SwiftUI

/// Blends the window title bar with the terminal (the title text comes from SwiftUI's
/// `.navigationTitle`/`.navigationSubtitle`): the probe's `window` is nil at make time, so the blend is
/// applied from `viewDidMoveToWindow` and re-applied on every `titleToken` change (session switch) and the
/// key/fullscreen transitions where AppKit rebuilds the titlebar subviews. It also carries the per-window
/// plumbing: persisting/restoring the frame, reporting frontmost (key/main) and close (`willClose`) to the
/// `WindowLibrary`, and registering the `NSWindow` in `WindowRegistry`.
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

        /// Observer tokens: AppKit rebuilds the titlebar subviews on key/fullscreen, so the blend re-applies.
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

        /// The current window title ("session — window"). Set on the OS window for the window menu and
        /// XCUITest title-matching, but hidden via titleVisibility — the custom header draws the visible one.
        private var latestTitle = ""

        func reapplyBlend(title: String) {
            latestTitle = title
            if let window { applyTitlebarBlend(window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
            titlebarObservers.removeAll()
            guard let window else { return }
            // the app owns its window set (WindowLibrary + windows.json reopen-all); SwiftUI's WindowGroup
            // restoration re-creates empty strays from its remembered count (shared by bundle id, not
            // isolated), so opt every real window fully out.
            window.isRestorable = false
            window.restorationClass = nil
            window.disableSnapshotRestoration()
            window.invalidateRestorableState()
            frameRestored = false
            // per-window geometry keyed by OUR window id: SwiftUI's WindowGroup autosaves under its own
            // index-based name ("terminal-AppWindow-N"), OVERRIDES any setFrameAutosaveName, and that index
            // loses a window's identity across an in-session close/reopen, landing it on the wrong slot. so
            // the frame is persisted on close under the stable window UUID and re-applied here, one-shot,
            // AFTER SwiftUI's initial .defaultSize pass.
            let frameKeyToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                DispatchQueue.main.async {
                    guard let self, let window, self.window === window else { return }
                    self.restoreSavedFrame(window)
                }
            }
            titlebarObservers.append(frameKeyToken)
            // fallback on the next run-loop tick, not a fixed delay, so the saved frame snaps in as soon as
            // SwiftUI's initial sizing pass ends, minimizing the visible default-then-resize.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.restoreSavedFrame(window)
            }
            // attach-race guard: a window.close that dropped this store mid-attach (window.new immediately
            // followed by window.close) leaves a zombie — close it rather than register it for a closed id.
            guard library.isOpen(windowID) else {
                DispatchQueue.main.async { [weak window] in
                    window?.orderOut(nil)
                    window?.close()
                }
                return
            }
            // register the NSWindow so the app raises this id's window (dedup) instead of spawning a second.
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
            // key/main/fullscreen transitions (becomeKey fires at launch), undoing the cleared titlebar layer
            // and glass tint — re-apply on every transition, resign included, or a background window falls
            // back to the lighter default glass.
            let frontmostNames: Set<NSNotification.Name> = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                         NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                // the @Sendable observer block can't touch main-actor state directly; hop through the main queue.
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
            // report close: tear down surfaces, then mark closed. captures library/store/id directly, NOT
            // `self` — the view deallocates as the window closes, so a `[weak self]` hop would no-op.
            let closeToken = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [library, store, windowID, weak window] _ in
                MainActor.assumeIsolated {
                    // persist the final frame (keyed by its id) so an in-session reopen or a restart restores
                    // size/position; SwiftUI's own index-based autosave can't.
                    if let window {
                        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: TitleProbeView.frameKey(windowID))
                    }
                    WindowRegistry.shared.unregister(windowID)
                    // unregister synchronously on the real AppKit close edge: the registry cancels any pending
                    // pick and retains its result for a poll arriving after the window and store are gone.
                    PickRegistry.shared.unregister(windowID)
                    store.finalizeAllPendingCloses()
                    // flush cwd drift before dropping the store — AppStore doesn't save on a live `cd`, so a
                    // reopened window would load a stale snapshot. skipped once the window is no longer open:
                    // a delete already dropped the store and removed the per-window file, so this resurrects it.
                    if library.isOpen(windowID) {
                        // restore-running-command: capture while the surfaces below are still alive. Skipped
                        // under termination — the quit-time capture already ran, and a re-read assigns
                        // unconditionally, so a foreground that exited since would overwrite it with nil.
                        // `openIDs()` is read before `closeWindow` runs, so it scopes this to the app-exit
                        // close. Contract in `.claude/rules/settings.md`.
                        if !library.isTerminating, library.openIDs() == [windowID],
                           GhosttyApp.shared.restoreRunningCommand {
                            AppDelegate.captureForegroundCommands(sessions: store.workspaces.flatMap(\.sessions))
                        } else if !library.isTerminating {
                            // a NON-last close must leave no argv in this window's file: a launch restore cannot
                            // tell it from a file open at exit, so the never-windowless reopen fallback could
                            // replay it. Before `restore.capture` the live field was always nil mid-run and the
                            // invariant held by construction; now it has to be enforced here.
                            // Termination belongs to NEITHER arm: `applicationWillTerminate` captured over live
                            // surfaces and persisted already, then `closeWindow` no-ops under the flag so this
                            // runs with the store still loaded. Clearing here writes nulls over that capture and
                            // every ⌘Q comes back a plain shell, `restore.capture` callers included.
                            for session in store.workspaces.flatMap(\.sessions) {
                                session.foregroundCommand = nil
                                session.splitForegroundCommand = nil
                                session.clearPendingForegroundCommands()
                            }
                        }
                        store.save()
                    }
                    for session in store.workspaces.flatMap(\.sessions) {
                        session.surface?.teardown()
                        session.splitSurface?.teardown()
                        session.overlaySurface?.teardown()
                        session.teardownPaneOverlays()
                        session.scratchSurface?.teardown()
                        session.discardHudBody() // an unrealized HUD has no teardown to delete its body file
                    }
                    library.closeWindow(windowID)
                    // the quick-terminal panel belongs to no window, so nothing above tore it down. Usually
                    // moot — an empty open set terminates the app — but a cancelled quit prompt leaves agterm
                    // running with no window, where `canShow` refuses a NEW show while a panel already up
                    // would linger as the only thing on screen.
                    if library.openIDs().isEmpty { QuickTerminalController.shared.hide() }
                    // closing a window drops its (unobserved) store, so the Dock badge's observation won't
                    // fire — refresh explicitly. guarded on isTerminating: at quit willClose fires after
                    // applicationWillTerminate's clear() and closeWindow no-ops (stores stay loaded), so the
                    // refresh would re-pin the zeroed badge.
                    if !library.isTerminating { DockBadgeController.shared.refresh() }
                }
            }
            titlebarObservers.append(closeToken)
            // a settings theme change updates GhosttyApp.terminalBackgroundColor; re-apply so the title bar
            // and transparent sidebar pick up the new window color live, not on the next re-key.
            let appearanceToken = NotificationCenter.default.addObserver(forName: .agtermAppearanceChanged, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    self.applyTitlebarBlend(window)
                }
            }
            titlebarObservers.append(appearanceToken)
            // A live Reduce Transparency flip must immediately force/restore effective opacity and blur.
            let accessibilityToken = NotificationCenter.default.addObserver(
                forName: .agtermAccessibilityDisplayOptionsChanged, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    self.applyTitlebarBlend(window)
                }
            }
            titlebarObservers.append(accessibilityToken)
            // a window restored miniaturized isn't on-screen, so a fresh launch shows nothing and UI-test
            // automation has nothing to hit. bring it forward un-minimized, re-asserted next tick because
            // state restoration can re-apply the miniaturized state right after the view attaches.
            bringForward(window)
            DispatchQueue.main.async { [weak self] in self?.bringForward(window) }
            scheduleUITestWindowForward(window)
            // a reopened/raised window can become key DURING creation, before these observers exist, missing
            // that initial didBecomeKey. report frontmost so the palette/session switcher route to THIS window.
            if window.isKeyWindow || window.isMainWindow { reportFrontmost(windowID) }
        }

        deinit {
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Record this window as frontmost in the library and persist the index. The persist and the
        /// frontmost-changed post are gated on an ACTUAL change, so the paired `didBecomeKey`/`didBecomeMain`
        /// (and a re-key) collapse to one write instead of a per-focus-change storm.
        @MainActor private func reportFrontmost(_ id: WindowInfo.ID) {
            let changed = library.frontmostWindowID != id
            if changed {
                library.frontmostWindowID = id
                library.saveIndex()
            }
            // auto-hide-inactive-sidebars: reconcile on EVERY activation report, even when the id is
            // unchanged — `newWindow()` pre-sets `frontmostWindowID` before the window keys and launch
            // restores it, so a changed-only gate would leave the prior window's sidebar showing (or the
            // restored frontmost collapsed). runs AFTER `frontmostWindowID` is set so `activeWindowID`
            // resolves here; never on resign, so switching apps leaves every sidebar untouched.
            if GhosttyApp.shared.autoHideSidebarInactiveWindows {
                library.applyInactiveWindowSidebarHiding()
            }
            // the active-window change is async; let the control server refresh its cached window list so a
            // `window.list` poll sees the new `active` flag without waiting for the next command.
            if changed {
                NotificationCenter.default.post(name: .agtermWindowFrontmostChanged, object: nil)
            }
        }

        private func bringForward(_ window: NSWindow) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }

        /// UserDefaults key for this window's saved frame, keyed by the stable window UUID.
        static func frameKey(_ id: WindowInfo.ID) -> String { "agterm-frame-\(id.uuidString)" }

        /// Applies the saved frame for this window id, once. Deferred (window-key / next tick) so SwiftUI's
        /// initial `.defaultSize` pass has run and won't clobber the restored geometry.
        private func restoreSavedFrame(_ window: NSWindow) {
            guard !frameRestored else { return }
            frameRestored = true
            guard let saved = UserDefaults.standard.string(forKey: Self.frameKey(windowID)) else { return }
            let frame = NSRectFromString(saved)
            guard frame.width > 0, frame.height > 0 else { return }
            window.setFrame(Self.constrainedRestoredFrame(frame, for: window), display: true)
        }

        /// Normalize a persisted frame before restore: a saved `NSRect` may come from a display no longer
        /// attached, which would put the relaunched window entirely off-screen. Keeps the saved size/position
        /// where possible, fully contained on a current screen.
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
        /// whatever delegate SwiftUI set.
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

        /// Re-assert the window forward under XCUITest: the FB11763863 reopen can present it slightly after
        /// the view attaches, so keep ordering it front for a short schedule.
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
            // present a window that isn't on screen yet (FB11763863: created minimized/background), then latch
            // off — re-fronting on a later tick (or a momentary !isVisible during a re-render) would fight a
            // deliberate window.select and oscillate the key window.
            guard !didPresentForUITests else { return }
            // already on screen: it presented itself, so latch NOW — leaving the remaining ticks armed is the
            // same hazard one step later, dragging a window.minimize-parked window back out of the Dock.
            guard window.isMiniaturized || !window.isVisible else {
                didPresentForUITests = true
                return
            }
            NSApp.unhide(nil)
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            didPresentForUITests = true
        }

        private func applyTitlebarBlend(_ window: NSWindow) {
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

// CoreGraphics <-> host-free WindowGeometry conversions for restore-frame clamping. the arithmetic lives in
// agtermCore so display-selection and off-screen restore edge cases stay unit-testable.
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

/// Forwarding `NSWindowDelegate` adding a confirm-before-close for a window with running sessions, passing
/// every other call to whatever delegate SwiftUI installed. Owned strongly by `TitleProbeView`
/// (`NSWindow.delegate` is weak). Intercepts USER closes (red button, File ▸ Close); `WindowRegistry.close`
/// uses `window.close()`, which skips `windowShouldClose`, so Delete Window / agtermctl don't double-prompt.
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
                // close() doesn't re-enter windowShouldClose (no re-prompt) but still runs the willClose
                // teardown + library mark-closed.
                sender.close()
            }
        }
        return false
    }

    private func forwardedShouldClose(_ sender: NSWindow) -> Bool {
        (forwardingDelegate as? NSWindowDelegate)?.windowShouldClose?(sender) ?? true
    }

    // forward every other NSWindowDelegate selector to SwiftUI's delegate so its window bookkeeping
    // (willClose, didResize, …) still runs. called by the ObjC runtime; reads the weak forward target.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardingDelegate?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        forwardingDelegate?.responds(to: selector) == true ? forwardingDelegate : super.forwardingTarget(for: selector)
    }
}
