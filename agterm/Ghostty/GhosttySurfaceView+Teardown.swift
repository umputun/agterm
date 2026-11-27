import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    func destroySurface() {
        // a second teardown must not reach finishDestroy: a retired surface may still be running
        guard !isDestroyed else { return }
        let surface = detachSurface()
        releaseCallbacksAndFiles()
        if let surface { ghostty_surface_free(surface) }
        finishDestroy()
    }

    /// destroySurface without waiting on the surface's threads. `ghostty_surface_free` joins them, and their
    /// exit polls with short sleeps that App Nap stretches to seconds, or never ends while the child ignores
    /// its hangup, so the surface is only asked to stop here and `retirement` frees it once they have exited.
    /// It stays allocated meanwhile, so no new surface can take its address (`agtermApp.replacePane`).
    func retireSurface(into retirement: SurfaceRetirement = .shared) {
        guard !isDestroyed else { return }
        let surface = detachSurface()
        // set before the store callbacks run, so a report libghostty's threads send meanwhile is dropped
        retired.withLock { $0 = true }
        releaseCallbacksAndFiles()
        guard let surface else { return finishDestroy() }
        if ghostty_surface_try_free(surface) { return finishDestroy() }
        retirement.retire(self, surface: surface)
    }
}
