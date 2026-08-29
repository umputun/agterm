import Foundation
import GhosttyKit
import os

private let visibilityLogger = Logger(subsystem: "com.umputun.agterm", category: "renderer-visibility")

extension GhosttySurfaceView {
    /// A short grace period prevents a SwiftUI reparent from tearing down and rebuilding the swap chain.
    static let rendererOcclusionDelay: UInt64 = 1_000_000_000
    /// How long a hide defers to a never-painted pane's first present; launch restores dozens of
    /// surfaces, so first paints can land tens of seconds late. Expiry hides anyway.
    static let firstPresentTimeout: UInt64 = 60_000_000_000
    static let firstPresentPoll: UInt64 = 250_000_000
    static let hiddenJanitorInterval: UInt64 = 30_000_000_000

    var showsOnScreen: Bool { deckOnScreen && window != nil }

    /// `delayHide: false` skips the reparent grace; every hide still lands AFTER the pane's first
    /// present. The renderer's release is edge-triggered, so an edge sent before the restore paints
    /// releases an empty chain and the paint then rebuilds it with no edge left to free it — the
    /// 2 GB launch floor. Waiting adds no protocol edge: the pane spawns visible and hides once,
    /// merely later. The intervals are parameters only so tests can shorten them.
    func updateRendererVisibility(
        delayHide: Bool = true,
        grace: UInt64 = GhosttySurfaceView.rendererOcclusionDelay,
        presentPoll: UInt64 = GhosttySurfaceView.firstPresentPoll,
        presentTimeout: UInt64 = GhosttySurfaceView.firstPresentTimeout
    ) {
        cancelPendingRendererVisibility()
        guard !showsOnScreen else {
            setRendererVisible(true)
            return
        }
        guard delayHide || layer?.contents == nil else {
            setRendererVisible(false)
            return
        }
        rendererVisibilityTask = Task { @MainActor [weak self] in
            if delayHide {
                try? await Task.sleep(nanoseconds: grace)
            }
            var waited: UInt64 = 0
            while !Task.isCancelled, waited < presentTimeout, self?.layer?.contents == nil {
                try? await Task.sleep(nanoseconds: presentPoll)
                waited += presentPoll
            }
            guard !Task.isCancelled, let self, !self.showsOnScreen else { return }
            self.rendererVisibilityTask = nil
            self.setRendererVisible(false)
        }
    }

    private func setRendererVisible(_ visible: Bool) {
        // libghostty's layer sets `needsDisplayOnBoundsChange` (Metal.zig), so a window resize makes
        // CA display every mounted hidden pane, rebuilding the swap chain the release just freed —
        // with no edge left to free it again. Drop the flag while renderer-hidden; ahead of the
        // surface guard so a hide settled before realization still gates CA.
        layer?.needsDisplayOnBoundsChange = visible
        guard let surface, rendererVisible != visible else { return }
        rendererVisible = visible
        visibilityLogger.debug("occlusion \(visible ? "visible" : "hidden", privacy: .public) session=\(self.session?.id.uuidString ?? "-", privacy: .public) split=\(self.isSplitPane)")
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            ghostty_surface_refresh(surface)
            // Refresh only QUEUES a render, so SwiftUI can expose the pane before anything presents —
            // blank where the janitor dropped the retained frame, or stale geometry after a hidden
            // resize. Draw synchronously (the API's sanctioned main-thread path; it also rebuilds a
            // released swap chain) for a nonblank frame at current bounds; output produced while
            // hidden arrives with the queued render.
            ghostty_surface_draw(surface)
        } else {
            startHiddenJanitor()
        }
    }

    /// The Metal backend declares no `gpuResourcesReleased`, so a released swap chain's
    /// last-presented IOSurface stays retained by the CALayer `contents`, and presents landing after
    /// the hide edge (launch restore, the CA display callback on resize) re-set it. Sweep the
    /// retained frame on a slow cadence while renderer-hidden. The CA path also rebuilds the chain
    /// itself, which only upstream can stop: never re-arm the release with an occlusion toggle here,
    /// `ghostty_surface_set_occlusion` is terminal visibility and leaks mode 2033 visibility reports
    /// to a program that stayed hidden throughout.
    /// `self` is bound per wake: a strong hold across the sleep would pin a discarded view against
    /// the `deinit` safety net. `destroySurface` cancels the task; a reveal retires it on wake.
    func startHiddenJanitor(interval: UInt64 = GhosttySurfaceView.hiddenJanitorInterval) {
        guard hiddenJanitorTask == nil else { return }
        hiddenJanitorTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: interval)
                guard let view = self, !Task.isCancelled, !view.rendererVisible else { break }
                view.layer?.contents = nil
            }
            self?.hiddenJanitorTask = nil
        }
    }

    func cancelPendingRendererVisibility() {
        rendererVisibilityTask?.cancel()
        rendererVisibilityTask = nil
    }
}
