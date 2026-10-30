import AppKit
import agtermCore

extension ControlServer {
    /// openImageLink shows a clicked local picture over its session, sized to the picture, and reports whether
    /// it did through `completion`; false reveals the file instead. The file is read off the main actor, and
    /// everything the open depends on is checked again after the read, since it may have changed meanwhile.
    func openImageLink(_ url: URL, session id: UUID, completion: @escaping @MainActor (Bool) -> Void) {
        guard canShowLinkOverlay(session: id) else { return completion(false) }
        let path = url.path(percentEncoded: false)
        Task { @MainActor [weak self] in
            let loaded = await ImageProbe.loadDetached(path: path)
            guard let self, case .success(let (probe, _)) = loaded, canShowLinkOverlay(session: id),
                  let store = library.store(forSession: id) else { return completion(false) }
            completion(openImageOverlay(in: store, sessionID: id, path: path, probe: probe,
                                        options: Self.imageOptions(path: path)).ok)
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
        guard options.pane == nil, options.sizePercent == nil, options.points.isEmpty else {
            return openHtmlOverlay(in: store, sessionID: id, page: .image(path: path), options: options)
        }
        let scale = library.windowID(forSession: id).flatMap(WindowRegistry.shared.backingScale)
            ?? Double(NSScreen.main?.backingScaleFactor ?? 1)
        let points = ImagePage.points(natural: probe.natural(scale: scale), zoom: HtmlOverlayRegistry.shared.zoom,
                                      bounds: store.session(withID: id)?.hudPaneFrames.detail)
        let sized = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: ImagePage.basePercent,
                                                     backgroundColor: options.backgroundColor, follow: options.follow,
                                                     page: options.page, points: points)
        return openHtmlOverlay(in: store, sessionID: id, page: .image(path: path), options: sized)
    }

    private static func imageOptions(path: String) -> ControlSessionOverlayOpenOptions {
        ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil,
                                         page: .image(path: path))
    }
}
