import agtermCore
import AppKit
import SwiftUI

extension NSView {
    /// The `NSSplitView` this view is arranged inside, nil when it is not in a split. Shared by the probe
    /// and by `GhosttySurfaceView.ownsPointer`, which both answer the divider from the split itself.
    func enclosingSplitView() -> NSSplitView? {
        var view: NSView? = superview
        while let current = view {
            if let split = current as? NSSplitView { return split }
            view = current.superview
        }
        return nil
    }
}

/// Bridges to the AppKit `NSSplitView` under SwiftUI's `HSplitView`/`VSplitView` to (1) persist and restore the split
/// divider ratio — no public SwiftUI API exposes the divider position — (2) clip the split's divider out
/// of the titlebar strip, (3) paint the divider's own resize cursor, which nothing else writes, and
/// (4) restore an even split on a divider double-click. Attached as a `.background` on the primary pane so
/// its `NSView` lives inside the split's view tree without becoming a third arranged pane.
///
/// (1) Once the split has a real axis extent it restores `session.splitRatio` via `setPosition`; on each divider
/// resize it writes the current primary-pane fraction back to the session, which the next `save()` (or the
/// quit-flush) persists, like a live cwd change.
///
/// (2) In COMPACT mode the SwiftUI `.padding(.top, titlebarHeight)` (30px) lands inside the window's
/// safe-area band, so the AppKit `NSSplitView` ignores it and grows to the FULL window height (verified:
/// its frame + both arranged panes span pt 0..windowHeight); the panes' top strip is then empty
/// terminal-bg (invisible against the window bg), but the divider draws BLACK through it — a streak up
/// through the transparent titlebar. The 48px inset clears the band, so normal mode is already bounded.
/// The fix is a CALayer mask hiding the split's top `titlebarHeight` strip: a layer mask clips without
/// reflowing the terminal grid (a SwiftUI `.mask`/`.clipped()` here scrolled the top row away), the empty
/// strip is harmless to clip, and it composes with translucency (revealing the window backing, never an
/// opaque color over the titlebar).
///
/// (4) A drag can't land exactly on 50/50, and `NSSplitView`'s own double-click gesture only collapses a
/// pane through the delegate SwiftUI owns, so the reset is recognized from a shared mouse monitor instead.
/// It sees the second click after the first one's divider-drag tracking loop ends, leaving dragging intact.
struct SplitRatioAccessor: NSViewRepresentable {
    let session: Session
    let titlebarHeight: CGFloat
    let suspended: Bool
    /// On screen and uncovered: the deck's `visible` minus any overlay or scratch over the panes. Gates (3)
    /// and (4) — a background session's split is still laid out at the full frame with its tracking area
    /// armed, so its divider column would paint over, and answer clicks meant for, whatever session IS on
    /// screen.
    let deckVisible: Bool
    let onPersist: () -> Void

    func makeNSView(context _: Context) -> SplitProbeView {
        let view = SplitProbeView(session: session)
        view.onPersist = onPersist
        view.titlebarHeight = titlebarHeight
        view.suspended = suspended
        view.deckVisible = deckVisible
        return view
    }
    func updateNSView(_ nsView: SplitProbeView, context _: Context) {
        nsView.onPersist = onPersist
        nsView.titlebarHeight = titlebarHeight // re-clip on a toolbar-mode change (changes titlebarHeight)
        nsView.suspended = suspended
        nsView.deckVisible = deckVisible
    }

    final class SplitProbeView: NSView {
        private let session: Session
        var onPersist: (() -> Void)?
        /// Top strip (in points) to clip the split's divider out of; updated on a toolbar-mode change.
        var titlebarHeight: CGFloat = 0 { didSet { if titlebarHeight != oldValue { updateDividerClip() } } }
        var deckVisible: Bool = true
        var suspended: Bool = false {
            didSet {
                guard suspended != oldValue else { return }
                saveWorkItem?.cancel()
                if !suspended { restored = false }
                needsLayout = true
            }
        }
        /// The probes a divider click is offered to, weak so a torn-down one drops out on its own. Every
        /// attached probe joins; `dividerOwns` then decides which single one actually holds that pixel.
        private static let claimants = NSHashTable<SplitProbeView>.weakObjects()
        private static var clickMonitor: Any?
        nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?
        nonisolated(unsafe) private var applyObserver: NSObjectProtocol?
        nonisolated(unsafe) private var saveWorkItem: DispatchWorkItem?
        private weak var splitView: NSSplitView?
        private var dividerClipMask: CALayer?
        private var dividerTracking: NSTrackingArea?
        private var restored = false
        /// Primary-pane extent at the previous in-band press, nil when that press missed the band.
        private var lastPressPrimaryExtent: CGFloat?
        /// A press was swallowed and its release is still to come.
        private var swallowedPress = false

        init(session: Session) {
            self.session = session
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Hand the tracking area back before the split outlives this probe: `NSTrackingArea` does not retain
        /// its owner, so a stale one would message a freed view on the next move. `layout()` reinstalls it,
        /// and re-claims divider clicks, if the probe is re-hosted.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            guard newWindow == nil else { return }
            Self.dropClaimant(self)
            detach()
        }

        override func layout() {
            super.layout()
            attachIfNeeded()
            updateDividerTracking()
            Self.addClaimant(self)
            updateDividerClip() // keep the titlebar-strip clip sized to the current split bounds
            guard !suspended else { return }
            guard !restored, let split = splitView else { return }
            if let ratio = session.splitRatio {
                let total = axisLength(of: split)
                guard total > 1 else { return } // wait for a real extent; retried on each layout pass
                split.setPosition(total * CGFloat(ratio), ofDividerAt: 0)
            }
            restored = true
        }

        /// Find the enclosing `NSSplitView` once it's in the tree, then observe divider moves.
        private func attachIfNeeded() {
            let enclosing = enclosingSplitView()
            if splitView !== enclosing { detach() }
            guard splitView == nil, let split = enclosing else { return }
            splitView = split
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main) { [weak self] _ in
                // the observer fires on the main queue; assume the main actor to call the @MainActor
                // `capture()`, matching the codebase's notification-closure pattern (e.g. ControlServer).
                MainActor.assumeIsolated { self?.capture() }
            }
            // `session.resize` stores a new fraction on the session and posts this (object-scoped to the
            // session) to move the LIVE divider — the programmatic analogue of a user drag, firing on
            // every resize command unlike the one-shot restore in `layout()`.
            applyObserver = NotificationCenter.default.addObserver(
                forName: .agtermApplySplitRatio, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyRatio() }
            }
        }

        private func detach() {
            if let dividerTracking { splitView?.removeTrackingArea(dividerTracking) }
            dividerTracking = nil
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let applyObserver { NotificationCenter.default.removeObserver(applyObserver) }
            resizeObserver = nil
            applyObserver = nil
            if let split = splitView, dividerClipMask != nil { split.layer?.mask = nil }
            dividerClipMask = nil
            splitView = nil
            restored = false
        }

        private func axisLength(of split: NSSplitView) -> CGFloat {
            split.isVertical ? split.bounds.width : split.bounds.height
        }

        private func primaryExtent(in split: NSSplitView) -> CGFloat {
            guard let first = split.arrangedSubviews.first else { return 0 }
            return split.isVertical ? first.frame.width : first.frame.height
        }

        /// Arm the split for `mouseMoved`/`cursorUpdate`. `.inVisibleRect` keeps it sized across divider and
        /// window resizes, so this only has to survive a re-host.
        private func updateDividerTracking() {
            guard let split = splitView else { return }
            if let dividerTracking, split.trackingAreas.contains(dividerTracking) { return }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            split.addTrackingArea(area)
            dividerTracking = area
        }

        /// Paint ↔ over the divider. Nothing else does once a second session is mounted: the pane declines the
        /// band (`ownsPointer`) and AppKit's own divider cursor never fires there, leaving the arrow. Per move
        /// plus one deferred re-assert, as the cursor section of `.claude/rules/libghostty.md` requires.
        override func mouseMoved(with event: NSEvent) { paintDividerCursor(at: event.locationInWindow) }
        override func cursorUpdate(with event: NSEvent) { paintDividerCursor(at: event.locationInWindow) }

        private func paintDividerCursor(at pointInWindow: NSPoint) {
            guard dividerOwns(pointInWindow) else { return }
            let cursor = splitView?.isVertical == false ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight
            cursor.set()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.isKeyWindow,
                      dividerOwns(window.mouseLocationOutsideOfEventStream) else { return }
                cursor.set()
            }
        }

        /// Whether THIS split's grab band owns the window point. The band is asked of the split itself, which
        /// is what its own drag resolves from, so no width is guessed — a window-down hit would answer for
        /// whichever session's split the deck stacked last, since all of them are mounted at the full frame.
        ///
        /// The cover is a separate question, and the window-down hit is what answers it, under `ownsPointer`'s
        /// chrome-only rule: another surface above means only invisible deck content covers the band, while a
        /// palette scrim, the search bar or the compact-mode titlebar strip means real chrome does.
        private func dividerOwns(_ pointInWindow: NSPoint) -> Bool {
            guard deckVisible, !suspended, let split = splitView, let parent = split.superview else { return false }
            guard split.hitTest(parent.convert(pointInWindow, from: nil)) === split else { return false }
            guard let hit = split.window?.contentView?.hitTest(pointInWindow) else { return true }
            return hit === split || hit.isDescendant(of: split) || hit is GhosttySurfaceView || hit is NSSplitView
        }

        /// Join the probes the click monitor asks, installing that monitor with the first split and dropping
        /// it once the last probe leaves its window, so an app that never splits installs none. ONE monitor
        /// for the whole app, like `PaneShortcuts` — never one per probe, which would run N predicates per
        /// click and leak a monitor on every re-attach. Adding is idempotent; `layout()` re-claims after a
        /// re-host. A probe freed without `viewWillMove(toWindow:)` leaves the monitor installed, which costs
        /// nothing: `claimants` is weak, so the handler finds it empty and passes every event through
        /// untouched. Removing it from inside its own dispatch is not worth that.
        private static func addClaimant(_ probe: SplitProbeView) {
            claimants.add(probe)
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                for claimant in claimants.allObjects where claimant.consumes(event) { return nil }
                return event
            }
        }

        private static func dropClaimant(_ probe: SplitProbeView) {
            claimants.remove(probe)
            guard claimants.allObjects.isEmpty, let monitor = clickMonitor else { return }
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }

        /// Whether this probe takes the event: a double-click on its divider, which restores the even split,
        /// or the release pairing with a press it already took — an unpaired release would otherwise reach
        /// whatever sits under the swallowed press.
        ///
        /// The target is `dividerOwns`, the same band the resize cursor is painted over and the same one the
        /// split's own drag already starts in, so the gesture takes no pixel the terminal could have used for
        /// a word selection. A press counts as a double-click only if the divider has not MOVED since the
        /// previous one: macOS reports `clickCount == 2` for a re-grab that lands close enough in time and
        /// space to the last press, so fine-tuning with a nudge-drag and grabbing again would otherwise throw
        /// the adjustment away and eat the second drag.
        func consumes(_ event: NSEvent) -> Bool {
            guard let split = splitView, event.window === split.window else { return false }
            if event.type == .leftMouseUp {
                defer { swallowedPress = false }
                return swallowedPress
            }
            guard split.arrangedSubviews.count == 2 else { return false }
            let onDivider = dividerOwns(event.locationInWindow)
            let primaryExtent = primaryExtent(in: split)
            defer { lastPressPrimaryExtent = onDivider ? primaryExtent : nil }
            guard onDivider, event.clickCount == 2,
                  let previous = lastPressPrimaryExtent, abs(previous - primaryExtent) < 1 else { return false }
            resetToEvenSplit()
            swallowedPress = true
            return true
        }

        /// Restore the even split through the `session.resize` path, so the model and the live divider move
        /// exactly as they do for a control-driven ratio. Persist straight away: this is one discrete action,
        /// not the drag stream `capture()` debounces.
        private func resetToEvenSplit() {
            session.splitRatio = AppStore.splitRatioDefault
            applyRatio()
            saveWorkItem?.cancel()
            onPersist?()
        }

        /// Move the live divider to the session's stored `splitRatio` (set by `session.resize` just before
        /// it posts `.agtermApplySplitRatio`). The follow-on `didResizeSubviews` → `capture()` is a no-op:
        /// the captured fraction equals what was just set, so `capture()`'s near-equal guard skips it.
        private func applyRatio() {
            guard !suspended else { restored = false; return }
            guard let split = splitView, let ratio = session.splitRatio else { return }
            let total = axisLength(of: split)
            // no real extent yet (mid-relayout): re-arm the one-shot `layout()` restore so it applies the
            // new fraction on the next pass instead of leaving the model ahead of the divider.
            guard total > 1 else { restored = false; return }
            split.setPosition(total * CGFloat(ratio), ofDividerAt: 0)
        }

        /// Mask the split's divider out of the titlebar zone — the strip ABOVE the window's titlebar
        /// boundary (`titlebarHeight` points from the content top) that the NSSplitView overruns into in
        /// compact mode. The clip amount is that overrun, computed live: ~`titlebarHeight` in compact (the
        /// split spans the full window) and 0 in normal (already bounded at the content top, where clipping
        /// a fixed strip would eat real terminal rows). A layer mask, not a frame change, so panes never reflow.
        private func updateDividerClip() {
            guard let split = splitView, let contentH = split.window?.contentView?.bounds.height else { return }
            guard split.isVertical else {
                if dividerClipMask != nil { split.layer?.mask = nil; dividerClipMask = nil }
                return
            }
            split.wantsLayer = true
            // split's top edge measured in points DOWN from the content top (window base coords, AppKit
            // origin bottom-left, so the top edge is maxY); then how far it rises above the titlebar boundary.
            let splitTopFromContentTop = contentH - split.convert(split.bounds, to: nil).maxY
            let overrun = max(0, titlebarHeight - splitTopFromContentTop)
            // no overrun (normal mode, or any state where the split is already bounded at the content top) →
            // no clip: drop the mask so the split composites untouched, like a single pane.
            guard overrun > 0 else {
                if dividerClipMask != nil { split.layer?.mask = nil; dividerClipMask = nil }
                return
            }
            let visibleHeight = max(0, split.bounds.height - overrun)
            // the mask's OPAQUE rect = the region that stays visible (everything below the overrun strip).
            // the strip sits at the view's TOP: high-y when not flipped, low-y (origin) when flipped.
            let originY = split.isFlipped ? overrun : 0
            let frame = CGRect(x: 0, y: originY, width: split.bounds.width, height: visibleHeight)
            let mask = dividerClipMask ?? CALayer()
            mask.backgroundColor = NSColor.black.cgColor // opaque -> the masked layer shows through here
            // no implicit fade as the mask resizes during a window/divider drag
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.frame = frame
            CATransaction.commit()
            if dividerClipMask == nil {
                dividerClipMask = mask
            }
            split.layer?.mask = mask // re-assert (SwiftUI may rebuild the split's layer)
        }

        /// Record the current primary-pane fraction onto the session, skipping no-op and degenerate values so
        /// a window resize that keeps the ratio doesn't churn it.
        private func capture() {
            guard !suspended else { return }
            guard restored, let split = splitView, let first = split.arrangedSubviews.first else { return }
            let total = axisLength(of: split)
            guard total > 1 else { return }
            let extent = split.isVertical ? first.frame.width : first.frame.height
            let ratio = Double(extent / total)
            guard ratio > AppStore.splitRatioMin, ratio < AppStore.splitRatioMax else { return }
            if let current = session.splitRatio, abs(current - ratio) < 0.004 { return }
            session.splitRatio = ratio
            // persist shortly after the drag settles (debounced) so a force-quit keeps it too, symmetric
            // with the sidebar width; coalesces the many resize ticks of one drag into a single save().
            saveWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onPersist?() }
            saveWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        deinit {
            saveWorkItem?.cancel()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let applyObserver { NotificationCenter.default.removeObserver(applyObserver) }
        }
    }
}
