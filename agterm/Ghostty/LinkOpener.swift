import AppKit
import agtermCore

/// LinkOpener carries out what `LinkPolicy.route` decides for a clicked terminal link. The app sets `mode`
/// and `overlay` once at launch; the defaults keep every link in the browser, which is also what a surface
/// gets before the control server exists.
@MainActor
struct LinkOpener {
    static var shared = LinkOpener()

    var mode: () -> LinkOpenMode = { .browser }
    /// overlay opens `url` as a browsing page over the session at the given size percent (nil for full size)
    /// and says whether it did; false sends the link to the browser.
    var overlay: (URL, UUID, Int?) -> Bool = { _, _, _ in false }
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    func follow(_ raw: String, from origin: LinkPolicy.ClickOrigin, wantsBrowser: Bool) {
        switch LinkPolicy.route(for: raw, mode: wantsBrowser ? .browser : mode(), origin: origin) {
        case .browser(let url): open(url)
        case .overlay(let url, let session, let percent): if !overlay(url, session, percent) { open(url) }
        case .reveal(let url): reveal(url)
        case .ignore: return
        }
    }
}
