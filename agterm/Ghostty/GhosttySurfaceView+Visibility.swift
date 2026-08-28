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
            startHiddenJanitor()
        }
    }

    /// The hide edge alone doesn't stick, twice over. The Metal backend declares no
    /// `gpuResourcesReleased`, so the released swap chain's last-presented IOSurface stays retained
    /// by the CALayer `contents`. Worse, the release is edge-triggered while draws are not gated on
    /// visibility: presents landing after the edge — a restore realizing dozens of surfaces after
    /// launch's early hide, the CA display callback firing on resize — quietly rebuild the whole
    /// chain, and no new edge ever re-releases it.
    /// So sweep on a slow cadence. A non-nil `contents` is the tell that a present landed since the
    /// last sweep: re-arm the edge with an occlusion toggle (the renderer re-releases whatever was
    /// rebuilt; the `true` half costs one off-screen frame), give that cycle's own present time to
    /// drain, then drop the retained frame. A settled surface reads as nil and the sweep is free.
    /// Nothing else may clear `contents` while hidden, or a live rebuilt chain reads as settled.
    /// An occluded pane paints nothing, and the reveal path refreshes before anything shows.
    /// `self` is bound per step: a strong hold across the long sleep would pin a discarded view
    /// against the `deinit` safety net for a cycle, or forever if it re-hides.
    private func startHiddenJanitor() {
        guard hiddenJanitorTask == nil else { return }
        hiddenJanitorTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let view = self, let surface = view.surface, !view.rendererVisible else { break }
                guard view.layer?.contents != nil else { continue }
                ghostty_surface_set_occlusion(surface, true)
                ghostty_surface_set_occlusion(surface, false)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let view = self, view.surface != nil, !view.rendererVisible else { break }
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
