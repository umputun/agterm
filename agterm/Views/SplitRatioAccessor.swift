import agtermCore
import AppKit
import SwiftUI

/// Bridges to the AppKit `NSSplitView` under SwiftUI's `HSplitView` to (1) persist and restore the split
/// divider ratio — no public SwiftUI API exposes the divider position — and (2) clip the split's divider out
/// of the titlebar strip. Attached as a `.background` on the primary pane so its `NSView` lives inside the
/// split's view tree without becoming a third arranged pane.
///
/// (1) Once the split has a real width it restores `session.splitRatio` via `setPosition`; on each divider
/// resize it writes the current left-pane fraction back to the session, which the next `save()` (or the
/// quit-flush) persists, like a live cwd change.
///
/// (2) In COMPACT mode the SwiftUI `.padding(.top, titlebarHeight)` (30px) lands inside the window's
/// safe-area band, so the AppKit `NSSplitView` ignores it and grows to the FULL window height (verified:
/// its frame + both arranged panes span pt 0..windowHeight). The panes' top strip is empty terminal-bg
/// (invisible against the window bg), but the divider draws BLACK through it — a streak up through the
/// transparent titlebar. A 48px inset clears the band so normal mode is already bounded. The fix is a
/// CALayer mask on the split that hides its top `titlebarHeight` strip: a layer mask clips without
/// reflowing the terminal grid (a SwiftUI `.mask`/`.clipped()` here scrolled the top row away), the panes'
/// empty top strip is harmless to clip, and it composes with translucency (it reveals the window backing,
/// never an opaque color over the titlebar).
struct SplitRatioAccessor: NSViewRepresentable {
    let session: Session
    let titlebarHeight: CGFloat
    let suspended: Bool
    let onPersist: () -> Void

    func makeNSView(context _: Context) -> SplitProbeView {
        let view = SplitProbeView(session: session)
        view.onPersist = onPersist
        view.titlebarHeight = titlebarHeight
        view.suspended = suspended
        return view
    }
    func updateNSView(_ nsView: SplitProbeView, context _: Context) {
        nsView.onPersist = onPersist
        nsView.titlebarHeight = titlebarHeight // re-clip on a toolbar-mode change (changes titlebarHeight)
        nsView.suspended = suspended
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
        nonisolated(unsafe) private var resizeObserver: NSObjectProtocol?
        nonisolated(unsafe) private var applyObserver: NSObjectProtocol?
        nonisolated(unsafe) private var saveWorkItem: DispatchWorkItem?
        private weak var splitView: NSSplitView?
        private var dividerClipMask: CALayer?
        private var restored = false

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
            // session) to move the LIVE divider — the programmatic analogue of a user drag. Unlike the
            // one-shot restore in `layout()`, it fires on every resize command.
            applyObserver = NotificationCenter.default.addObserver(
                forName: .agtermApplySplitRatio, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyRatio() }
            }
        }

        /// Move the live divider to the session's stored `splitRatio` (set by `session.resize` just before
        /// it posts `.agtermApplySplitRatio`). The follow-on `didResizeSubviews` → `capture()` is a no-op:
        /// the captured fraction equals the value we just set, so `capture()`'s near-equal guard skips it.
        private func applyRatio() {
            guard !suspended else { restored = false; return }
            guard let split = splitView, let ratio = session.splitRatio else { return }
            let total = split.bounds.width
            // no real width yet (mid-relayout): re-arm the one-shot `layout()` restore so it applies the
            // new fraction on the next pass instead of leaving the model ahead of the divider.
            guard total > 1 else { restored = false; return }
            split.setPosition(total * CGFloat(ratio), ofDividerAt: 0)
        }

        /// Mask the split's divider out of the titlebar zone — the strip ABOVE the window's titlebar boundary
        /// (`titlebarHeight` points from the content top) that the NSSplitView overruns into in compact mode.
        /// The clip amount is the split's overrun ABOVE that boundary, computed live: ~`titlebarHeight` in
        /// compact (the split spans the full window) and 0 in normal (the split is already bounded at the
        /// content top, so clipping a fixed strip would eat real terminal rows). A layer mask, not a frame
        /// change, so the panes never reflow.
        private func updateDividerClip() {
            guard let split = splitView, let contentH = split.window?.contentView?.bounds.height else { return }
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

        /// Record the current left-pane fraction onto the session, skipping no-op and degenerate values so a
        /// window resize that keeps the ratio doesn't churn it.
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
