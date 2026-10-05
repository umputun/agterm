import AppKit
import agtermCore

/// LinkOpener carries out what `LinkPolicy.route` decides for a clicked terminal link. The app sets `mode`
/// and `overlay` once at launch; the defaults keep every link in the browser, which is also what a surface
/// gets before the control server exists.
@MainActor
struct LinkOpener {
    static var shared = LinkOpener()

    var mode: () -> LinkOpenMode = { .browser }
    /// overlay opens `url` as a browsing page over the session and says whether it did; false sends the
    /// link to the browser.
    var overlay: (URL, UUID) -> Bool = { _, _ in false }
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    func follow(_ raw: String, from origin: LinkPolicy.ClickOrigin) {
        switch LinkPolicy.route(for: raw, mode: mode(), origin: origin) {
        case .browser(let url): open(url)
        case .overlay(let url, let session): if !overlay(url, session) { open(url) }
        case .reveal(let url): reveal(url)
        case .ignore: return
        }
    }
}
