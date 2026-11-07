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
    /// image shows a local picture over the session and reports through its completion whether it did; false
    /// reveals the file. The report can come later, the file being read off the main actor.
    var image: (URL, UUID, @escaping @MainActor (Bool) -> Void) -> Void = { _, _, done in done(false) }
    /// markdown renders a local markdown file over the session at the given size percent (nil for full size) and
    /// reports through its completion whether it did; false reveals the file.
    var markdown: (URL, UUID, Int?, @escaping @MainActor (Bool) -> Void) -> Void = { _, _, _, done in done(false) }
    /// text shows a local text file over its session and reports through its completion whether it did; false
    /// reveals the file.
    var text: (LinkPolicy.TextLink, @escaping @MainActor (Bool) -> Void) -> Void = { _, done in done(false) }
    /// document shows a local HTML file over the session at the given size percent (nil for full size), with no file
    /// grant or bridge, and reports through its completion whether it did; false reveals the file.
    var document: (URL, UUID, Int?, @escaping @MainActor (Bool) -> Void) -> Void = { _, _, _, done in done(false) }
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// exists answers for one candidate `LinkPolicy.locations` offered; it runs off the main actor.
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    /// follow carries out a clicked link; `cwd` is the clicking pane's directory, for a relative link. A link that
    /// only the filesystem can resolve is looked up off the main actor, the first existing candidate winning, and
    /// one with no candidate on disk keeps the route it has as typed. A reveal intent selects the file a local
    /// route names in Finder after that guarded routing, and leaves a web link to its web route.
    func follow(_ raw: String, from origin: LinkPolicy.ClickOrigin, cwd: String?, intent: LinkPolicy.ClickIntent) {
        let mode = intent == .browser ? LinkOpenMode.browser : mode()
        let reveals = intent == .reveal
        let candidates = LinkPolicy.locations(for: raw, origin: origin, cwd: cwd)
        guard !candidates.isEmpty else { return carryOut(LinkPolicy.route(for: raw, mode: mode, origin: origin), revealing: reveals) }
        let exists = exists
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) { candidates.first { exists($0.path) } }.value
            carryOut(found.map { LinkPolicy.route(for: $0, mode: mode, origin: origin) }
                ?? LinkPolicy.route(for: raw, mode: mode, origin: origin), revealing: reveals)
        }
    }

    private func carryOut(_ route: LinkPolicy.Route, revealing: Bool) {
        if revealing, let file = route.localFile { return reveal(file) }
        switch route {
        case .browser(let url): open(url)
        case .overlay(let url, let session, let percent): if !overlay(url, session, percent) { open(url) }
        case .image(let url, let session):
            let reveal = reveal
            image(url, session) { shown in if !shown { reveal(url) } }
        case .markdown(let url, let session, let percent):
            let reveal = reveal
            markdown(url, session, percent) { shown in if !shown { reveal(url) } }
        case .text(let link):
            let reveal = reveal
            text(link) { shown in if !shown { reveal(link.url) } }
        case .document(let url, let session, let percent):
            let reveal = reveal
            document(url, session, percent) { shown in if !shown { reveal(url) } }
        case .reveal(let url): reveal(url)
        case .ignore: return
        }
    }
}
