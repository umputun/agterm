import Foundation
import GhosttyKit
import os

private let visibilityLogger = Logger(subsystem: "com.umputun.agterm", category: "renderer-visibility")

extension GhosttySurfaceView {
    /// A short grace period prevents a SwiftUI reparent from tearing down and rebuilding the swap chain.
    static let rendererOcclusionDelay: UInt64 = 1_000_000_000

    var showsOnScreen: Bool { deckOnScreen && window != nil }

    func updateRendererVisibility(delayHide: Bool = true) {
        cancelPendingRendererVisibility()
        guard !showsOnScreen else {
            setRendererVisible(true)
            return
        }
        guard delayHide else {
            setRendererVisible(false)
            return
        }
        rendererVisibilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.rendererOcclusionDelay)
            guard !Task.isCancelled, let self, !self.showsOnScreen else { return }
            self.rendererVisibilityTask = nil
            self.setRendererVisible(false)
        }
    }

    private func setRendererVisible(_ visible: Bool) {
        guard let surface, rendererVisible != visible else { return }
        rendererVisible = visible
        visibilityLogger.notice("occlusion \(visible ? "visible" : "hidden", privacy: .public) session=\(self.session?.id.uuidString ?? "-", privacy: .public) split=\(self.isSplitPane)")
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            ghostty_surface_refresh(surface)
        } else {
            scheduleHiddenContentsDrop()
            startHiddenJanitor()
        }
    }

    /// The fixed drop passes lose to launch congestion: with dozens of surfaces restoring at once, a
    /// first present can land later than any reasonable delay, re-retaining the drawable until the
    /// next hide edge. Sweep on a slow cadence for as long as the surface stays renderer-hidden.
    /// `self` is bound only for the sweep itself: a strong hold across the sleep would pin a
    /// discarded view against the `deinit` safety net for a cycle, or forever if it re-hides.
    private func startHiddenJanitor() {
        guard hiddenJanitorTask == nil else { return }
        hiddenJanitorTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let view = self, view.surface != nil, !view.rendererVisible else { break }
                view.layer?.contents = nil
            }
            self?.hiddenJanitorTask = nil
        }
    }

    /// The Metal backend declares no `gpuResourcesReleased`, so after the renderer frees a hidden
    /// surface's swap chain the CALayer `contents` still retains its last-presented IOSurface —
    /// one full drawable per ever-viewed surface, forever. Drop that reference ourselves, AFTER the
    /// renderer has drained the occlusion message and released (the delay covers one in-flight
    /// present re-setting `contents` behind us). An occluded pane paints nothing, and the reveal
    /// path refreshes before anything shows.
    /// Two passes, not one: the delay is not synchronized with the renderer's in-flight frame
    /// completions, and a straggler present after the first pass would re-set `contents` and
    /// quietly re-retain the drawable. The second pass is far outside any real completion window.
    private func scheduleHiddenContentsDrop() {
        for delay in [0.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.rendererVisible, self.surface != nil else { return }
                self.layer?.contents = nil
            }
        }
    }

    func cancelPendingRendererVisibility() {
        rendererVisibilityTask?.cancel()
        rendererVisibilityTask = nil
    }
}
