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
    var selectSession: (UUID, LinkPolicy.ClickOrigin, UUID?) -> Void = { _, _, _ in }
    /// sessionName names the row `selectSession` would select for the same link, nil when it would select none.
    var sessionName: (UUID, LinkPolicy.ClickOrigin, UUID?) -> String? = { _, _, _ in nil }
    /// exists answers for one candidate `LinkPolicy.locations` offered; it runs off the main actor.
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// forward hands a path clicked in a remote pane to the Mac it names a file on, with the clicked pane when the click
    /// may run an `open` rule there; nil when sent, else why not.
    var forward: (RemoteLinkClick, GhosttySurfaceView?) -> RemoteLinkRefusal? = { _, _ in .originTooOld }
    /// refuse reports a remote click that was not carried out.
    var refuse: (UUID, RemoteLinkRefusal) -> Void = { _, _ in NSSound.beep() }
    /// loopback reaches a loopback URL on row `UUID`'s host through a forward from this Mac and reports the local URL
    /// once the forward answers, nil when it cannot; a row that goes away first gets no report.
    var loopback: (ForwardedPage, UUID, @escaping @MainActor (URL?) -> Void) -> Void = { _, _, done in done(nil) }
    /// opener names the user `open` rule for a clicked file's basename, nil when none takes it.
    var opener: (String) -> FileOpener? = { _ in nil }
    /// isRegularFile says, off the main actor, whether a path is a regular file a rule may receive.
    var isRegularFile: @Sendable (String) -> Bool = {
        if case .success = BoundedFile.check(path: $0, maxBytes: .max) { return true }
        return false
    }
    /// runOpener launches a rule on a clicked file with the clicked pane's context.
    var runOpener: (FileOpener, URL, GhosttySurfaceView) -> Void = { _, _, _ in }

    private struct Click {
        let origin: LinkPolicy.ClickOrigin
        let pane: UUID?
        let mode: LinkOpenMode
        let reveals: Bool
        let intent: LinkPolicy.ClickIntent
        let source: LinkPolicy.ClickSource
        let remote: UUID?
        weak var surface: GhosttySurfaceView?
    }

    struct Gesture {
        let intent: LinkPolicy.ClickIntent
        let source: LinkPolicy.ClickSource
    }

    /// follow carries out a clicked link; `cwd` is the clicking pane's directory, for a relative link, and `pane` its
    /// identity, which a remote pane's forwarded click names, and `remote` the row whose host runs the clicked program,
    /// whose loopback a web link then names. A link that only the filesystem can resolve is looked up
    /// off the main actor, the first existing candidate winning, and one with no candidate on disk keeps the route it
    /// has as typed. A reveal intent selects the file a local route names in Finder after that guarded routing, and
    /// leaves a web link to its web route. `surface` is the clicked pane, held weakly, whose context a user `open`
    /// rule runs with.
    func follow(_ raw: String, from origin: LinkPolicy.ClickOrigin, pane: UUID?, cwd: String?, gesture: Gesture,
                remote: UUID? = nil, surface: GhosttySurfaceView? = nil) {
        let intent = gesture.intent
        let click = Click(origin: origin, pane: pane, mode: intent == .browser ? LinkOpenMode.browser : mode(),
                          reveals: intent == .reveal, intent: intent, source: gesture.source, remote: remote, surface: surface)
        let candidates = LinkPolicy.locations(for: raw, origin: origin, cwd: cwd)
        guard !candidates.isEmpty else { return carryOut(LinkPolicy.route(for: raw, mode: click.mode, origin: origin), click) }
        let exists = exists
        Task { @MainActor in
            let route = await Task.detached(priority: .userInitiated) {
                LinkPolicy.resolvedRoute(for: raw, candidates: candidates, mode: click.mode, origin: origin, exists: exists)
            }.value
            carryOut(route, click)
        }
    }

    private func carryOut(_ route: LinkPolicy.Route, _ click: Click) {
        guard click.surface != nil, let file = LinkPolicy.openerFile(for: route, source: click.source, intent: click.intent),
              let rule = opener(file.lastPathComponent) else { return preview(route, click) }
        let isRegularFile = isRegularFile
        Task { @MainActor in
            let regular = await Task.detached(priority: .userInitiated) { isRegularFile(file.path) }.value
            guard regular else { return preview(route, click) }
            guard let surface = click.surface else { return }
            runOpener(rule, file, surface)
        }
    }

    private func preview(_ route: LinkPolicy.Route, _ click: Click) {
        if click.reveals, let file = route.localFile { return reveal(file) }
        switch route {
        case .selectSession(let id):
            guard !click.reveals else { return }
            selectSession(id, click.origin, click.pane)
        case .browser(let url):
            forwarding(url, click) { open($0) }
        case .overlay(let url, let session, let percent):
            forwarding(url, click) { local in if !overlay(local, session, percent) { open(local) } }
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
        case .forwardRemote(let raw, let session):
            if click.reveals { return refuse(session, .revealIntent) }
            let ruleSurface = click.source == .detected && click.intent == .normal ? click.surface : nil
            if let refusal = forward(RemoteLinkClick(raw: raw, session: session, pane: click.pane, mode: click.mode), ruleSurface) {
                refuse(session, refusal)
            }
        case .ignore: return
        }
    }

    /// forwarding hands `url` to `use` as typed, or, for a loopback URL clicked in a program running on another host,
    /// as the local end of a forward to that host once it answers; a forward that fails is refused on the row.
    private func forwarding(_ url: URL, _ click: Click, use: @escaping @MainActor (URL) -> Void) {
        guard let row = click.remote, let page = ForwardedPage(url.absoluteString) else { return use(url) }
        let refuse = refuse
        loopback(page, row) { local in
            guard let local else { return refuse(row, .forwardFailed) }
            use(local)
        }
    }
}
