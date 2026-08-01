import agtermCore
import AppKit
import SwiftUI

/// Bridges to the AppKit `NSSplitView` under SwiftUI's `HSplitView` to (1) persist and restore the split
/// divider ratio — no public SwiftUI API exposes the divider position — (2) reset it to an even split on a
/// divider double-click, and (3) clip the split's divider out of the titlebar strip. Attached as a
/// `.background` on the primary pane so its `NSView` lives inside the split's view tree without becoming a
/// third arranged pane.
///
/// (1) Once the split has a real width it restores `session.splitRatio` via `setPosition`; on each divider
/// resize it writes the current left-pane fraction back to the session, which the next `save()` (or the
/// quit-flush) persists, like a live cwd change.
///
/// (2) A drag can't land exactly on 50/50, and `NSSplitView`'s own double-click gesture only collapses a
/// pane through the delegate SwiftUI owns. So the reset is recognized from ONE app-wide mouse monitor
/// (`installClickMonitorIfNeeded`) instead: it sees the second click after the first one's divider-drag
/// tracking loop ends, leaving dragging intact.
///
/// (3) In COMPACT mode the SwiftUI `.padding(.top, titlebarHeight)` (30px) lands inside the window's
/// safe-area band, so the AppKit `NSSplitView` ignores it and grows to the FULL window height (verified:
/// its frame + both arranged panes span pt 0..windowHeight); the panes' top strip is then empty
/// terminal-bg (invisible against the window bg), but the divider draws BLACK through it — a streak up
/// through the transparent titlebar. The 48px inset clears the band, so normal mode is already bounded.
/// The fix is a CALayer mask hiding the split's top `titlebarHeight` strip: a layer mask clips without
/// reflowing the terminal grid (a SwiftUI `.mask`/`.clipped()` here scrolled the top row away), the empty
/// strip is harmless to clip, and it composes with translucency (revealing the window backing, never an
/// opaque color over the titlebar).
struct SplitRatioAccessor: NSViewRepresentable {
    let session: Session
    let titlebarHeight: CGFloat
    let suspended: Bool
    /// This session's panes are the ones on screen AND nothing covers them, so divider clicks are this
    /// probe's to answer. The deck's `visible` alone is not enough: it stays true under a FLOATING overlay,
    /// whose own terminal would then pass the chrome hit test and hand the gesture a click meant for it.
    let dividerEligible: Bool
    let onPersist: () -> Void

    func makeNSView(context _: Context) -> SplitProbeView {
        let view = SplitProbeView(session: session)
        view.onPersist = onPersist
        view.titlebarHeight = titlebarHeight
        view.suspended = suspended
        view.dividerEligible = dividerEligible
        return view
    }
    func updateNSView(_ nsView: SplitProbeView, context _: Context) {
        nsView.onPersist = onPersist
        nsView.titlebarHeight = titlebarHeight // re-clip on a toolbar-mode change (changes titlebarHeight)
        nsView.suspended = suspended
        nsView.dividerEligible = dividerEligible
    }

    final class SplitProbeView: NSView {
        private let session: Session
        var onPersist: (() -> Void)?
        /// Top strip (in points) to clip the split's divider out of; updated on a toolbar-mode change.
        var titlebarHeight: CGFloat = 0 { didSet { if titlebarHeight != oldValue { updateDividerClip() } } }
        var suspended: Bool = false {
            didSet {
                guard suspended != oldValue else { return }
                saveWorkItem?.cancel()
                if !suspended { restored = false }
                needsLayout = true
            }
        }
        var dividerEligible: Bool = false {
            didSet {
                guard dividerEligible != oldValue else { return }
                if dividerEligible { Self.claimants.add(self) } else { Self.claimants.remove(self) }
            }
        }
        /// Grab slop each side of the divider gap, so the double-click target matches the band AppKit already
        /// lets you start a drag in rather than the 1pt line.
        private static let dividerGrabSlop: CGFloat = 3
        /// The probes currently answering divider clicks — one per window with an uncovered split on screen.
        /// Weak, so a torn-down probe drops out on its own: `NSEvent.removeMonitor` in a nonisolated `deinit`
        /// has no main-thread guarantee, and the shared monitor below is never removed anyway.
        private static let claimants = NSHashTable<SplitProbeView>.weakObjects()
        private static var clickMonitor: Any?
        nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?
        nonisolated(unsafe) private var applyObserver: NSObjectProtocol?
        nonisolated(unsafe) private var saveWorkItem: DispatchWorkItem?
        private weak var splitView: NSSplitView?
        private var dividerClipMask: CALayer?
        private var restored = false
        /// Left-pane width at the previous in-band press, nil when that press missed the band.
        private var lastPressLeftWidth: CGFloat?
        /// A press was swallowed and its release is still to come.
        private var swallowedPress = false

        init(session: Session) {
            self.session = session
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            attachIfNeeded()
            updateDividerClip() // keep the titlebar-strip clip sized to the current split bounds
            guard !suspended else { return }
            guard !restored, let split = splitView else { return }
            if let ratio = session.splitRatio {
                let total = split.bounds.width
                guard total > 1 else { return } // wait for a real width; retried on each layout pass
                split.setPosition(total * CGFloat(ratio), ofDividerAt: 0)
            }
            restored = true
        }

        /// Find the enclosing `NSSplitView` once it's in the tree, then observe divider moves.
        private func attachIfNeeded() {
            guard splitView == nil, let split = enclosingSplitView() else { return }
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
            Self.installClickMonitorIfNeeded()
        }

        /// ONE monitor for the whole app, like `PaneShortcuts` — never one per probe, which would run N
        /// predicates per click and leak a monitor on every re-attach. It outlives every probe (a torn-down
        /// one simply leaves `claimants`), so it is installed once and never removed.
        private static func installClickMonitorIfNeeded() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                for probe in claimants.allObjects where probe.consumes(event) { return nil }
                return event
            }
        }

        /// Whether this probe takes the event: a double-click on its divider, which restores the even split,
        /// or the release pairing with a press it already took — an unpaired release would otherwise reach
        /// the surface under the swallowed press and report a phantom button-up to a mouse-reporting TUI.
        ///
        /// A press counts as a double-click only if the divider has not MOVED since the previous one: macOS
        /// reports `clickCount == 2` for a re-grab that lands close enough in time and space to the last
        /// press, so fine-tuning the divider with a nudge-drag and grabbing it again would otherwise throw
        /// the adjustment away and eat the second drag.
        private func consumes(_ event: NSEvent) -> Bool {
            guard !suspended, let split = splitView, event.window === split.window else { return false }
            if event.type == .leftMouseUp {
                defer { swallowedPress = false }
                return swallowedPress
            }
            guard split.arrangedSubviews.count == 2, let band = dividerBand(of: split) else { return false }
            let leftWidth = split.arrangedSubviews[0].frame.width
            let point = split.convert(event.locationInWindow, from: nil)
            let onDivider = band.contains(x: Double(point.x), y: Double(point.y))
                && terminalOwnsHit(event.locationInWindow, host: split)
            defer { lastPressLeftWidth = onDivider ? leftWidth : nil }
            guard onDivider, event.clickCount == 2,
                  let previous = lastPressLeftWidth, abs(previous - leftWidth) < 1 else { return false }
            resetToEvenSplit()
            swallowedPress = true
            return true
        }

        /// Where a click counts as landing on the divider, nil while the split has no window to measure
        /// against. `terminalOwnsHit` then rejects chrome drawn over it, and the masked titlebar strip is
        /// already outside the band.
        private func dividerBand(of split: NSSplitView) -> SplitDividerBand? {
            guard let clipped = titlebarOverrun(of: split) else { return nil }
            return SplitDividerBand(leftPaneMaxX: Double(split.arrangedSubviews[0].frame.maxX),
                                    rightPaneMinX: Double(split.arrangedSubviews[1].frame.minX),
                                    dividerThickness: Double(split.dividerThickness),
                                    grabSlop: Double(Self.dividerGrabSlop),
                                    visibleTop: Double(split.isFlipped ? clipped : 0),
                                    visibleHeight: Double(split.bounds.height - clipped))
        }

        /// Restore the even split, reusing the `session.resize` path so the model and the live divider move
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
            let total = split.bounds.width
            // no real width yet (mid-relayout): re-arm the one-shot `layout()` restore so it applies the
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
            // an off-window split cannot be measured; leave any installed mask alone rather than dropping it
            // and streaking the divider through the titlebar until the next layout pass re-installs it.
            guard let split = splitView, let overrun = titlebarOverrun(of: split) else { return }
            split.wantsLayer = true
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

        /// How far the split rises above the titlebar boundary — the strip whose divider is masked away —
        /// or nil with no window to measure against. Measure the split's top edge in points DOWN from the
        /// content top (window base coords, AppKit origin bottom-left, so the top edge is maxY).
        private func titlebarOverrun(of split: NSSplitView) -> CGFloat? {
            guard let contentH = split.window?.contentView?.bounds.height else { return nil }
            return max(0, titlebarHeight - (contentH - split.convert(split.bounds, to: nil).maxY))
        }

        /// Record the current left-pane fraction onto the session, skipping no-op and degenerate values so
        /// a window resize that keeps the ratio doesn't churn it.
        private func capture() {
            guard !suspended else { return }
            guard restored, let split = splitView, let first = split.arrangedSubviews.first else { return }
            let total = split.bounds.width
            guard total > 1 else { return }
            let ratio = Double(first.frame.width / total)
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

        private func enclosingSplitView() -> NSSplitView? {
            var view: NSView? = superview
            while let current = view {
                if let split = current as? NSSplitView { return split }
                view = current.superview
            }
            return nil
        }

        deinit {
            saveWorkItem?.cancel()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let applyObserver { NotificationCenter.default.removeObserver(applyObserver) }
        }
    }
}
