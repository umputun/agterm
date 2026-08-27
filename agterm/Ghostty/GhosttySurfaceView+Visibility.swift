import Foundation
import GhosttyKit

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
        ghostty_surface_set_occlusion(surface, visible)
        if visible { ghostty_surface_refresh(surface) }
    }

    func cancelPendingRendererVisibility() {
        rendererVisibilityTask?.cancel()
        rendererVisibilityTask = nil
    }
}
