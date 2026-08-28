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

    /// Sweep cadence for `startHiddenJanitor`; tests shorten it.
    static var hiddenJanitorInterval: UInt64 = 30_000_000_000

    private func setRendererVisible(_ visible: Bool) {
        guard let surface, rendererVisible != visible else { return }
        rendererVisible = visible
        visibilityLogger.debug("occlusion \(visible ? "visible" : "hidden", privacy: .public) session=\(self.session?.id.uuidString ?? "-", privacy: .public) split=\(self.isSplitPane)")
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            ghostty_surface_refresh(surface)
            // The janitor dropped the retained frame and refresh only QUEUES a render, so SwiftUI
            // can expose the pane before anything presents. Draw synchronously (supported from the
            // main thread; it also rebuilds a released swap chain) so a cleared layer never shows.
            if layer?.contents == nil {
                ghostty_surface_draw(surface)
            }
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
    func startHiddenJanitor() {
        guard hiddenJanitorTask == nil else { return }
        hiddenJanitorTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.hiddenJanitorInterval)
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
