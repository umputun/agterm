import AppKit
import agtermCore

extension ControlServer {
    /// openImageLink shows a clicked local picture over its session, sized to the picture, and reports whether
    /// it did through `completion`. The file is read off the main actor, and
    /// everything the open depends on is checked again after the read, since it may have changed meanwhile.
    func openImageLink(_ url: URL, session id: UUID, forward: Int? = nil, completion: @escaping @MainActor (Bool) -> Void) {
        guard canShowLinkOverlay(session: id, forwarded: forward != nil) else { return completion(false) }
        let path = url.path(percentEncoded: false)
        Task { @MainActor [weak self] in
            let loaded = await ImageProbe.loadDetached(path: path)
            guard let self, case .success(let (probe, _)) = loaded, canShowLinkOverlay(session: id, forwarded: forward != nil),
                  forwardIsCurrent(forward, session: id), let store = library.store(forSession: id) else { return completion(false) }
            if forward == nil { releaseHiddenClickedPage(session: id, persistent: false) }
            completion(openImageOverlay(in: store, sessionID: id, path: path, probe: probe,
                                        options: Self.imageOptions(path: path, forwarded: forward != nil)).ok)
        }
    }

    /// openImageFile reads and probes the picture at `path` on the calling thread, then opens it.
    func openImageFile(in store: AppStore, sessionID id: UUID, path: String,
                       options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        switch ImageProbe.load(path: path) {
        case .failure(let failure): return ControlResponse(ok: false, error: "session.overlay.open: \(failure)")
        case .success(let (probe, _)): return openImageOverlay(in: store, sessionID: id, path: path, probe: probe, options: options)
        }
    }

    /// openImageOverlay opens a probed picture: a session-wide panel the caller gave no size is sized to it, in
    /// the session's detail area at the density of the screen its window is on. Sized once; a later resize
    /// replaces it. It reads nothing, so the control path's synchronous probe and the click's detached one
    /// share it.
    func openImageOverlay(in store: AppStore, sessionID id: UUID, path: String, probe: ImageProbe,
                          options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        if store.session(withID: id)?.overlayHidden(options.pane) == true {
            return ControlResponse(ok: false, error: OverlayVisibilityError.hidden)
        }
        let natural = probe.natural(scale: 1)
        let pixels = ImagePixels(width: Int(natural.width), height: Int(natural.height))
        // the presenting Mac sizes an unsized picture for its own screen, so it gets the pixels and no points
        guard options.pane == nil, options.sizePercent == nil, options.points.isEmpty,
              !store.pageBelongsRemote(id, pane: nil) else {
            return openHtmlOverlay(in: store, sessionID: id, page: .image(path: path), options: options.with(imagePixels: pixels))
        }
        let points = imagePoints(in: store, sessionID: id, pixels: pixels)
        let sized = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: ImagePage.basePercent,
                                                     backgroundColor: options.backgroundColor, follow: options.follow,
                                                     page: options.page, points: points, clicked: options.clicked,
                                                     forwarded: options.forwarded)
        return openHtmlOverlay(in: store, sessionID: id, page: .image(path: path), options: sized)
    }

    /// imagePoints sizes a picture of `pixels` for the session's detail area, at the density of the screen its
    /// window is on; the origin sizes its own pages with it and the presenting Mac the pictures handed to it.
    func imagePoints(in store: AppStore, sessionID id: UUID, pixels: ImagePixels) -> OverlayPointSize {
        let scale = library.windowID(forSession: id).flatMap(WindowRegistry.shared.backingScale)
            ?? Double(NSScreen.main?.backingScaleFactor ?? 1)
        let natural = ImagePage.natural(pixelWidth: pixels.width, pixelHeight: pixels.height, orientation: 1, scale: scale)
        return ImagePage.points(natural: natural, zoom: HtmlOverlayRegistry.shared.zoom,
                                bounds: store.session(withID: id)?.hudPaneFrames.detail)
    }

    private static func imageOptions(path: String, forwarded: Bool) -> ControlSessionOverlayOpenOptions {
        ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                         page: .image(path: path), clicked: true, forwarded: forwarded)
    }
}
