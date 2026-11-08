import Foundation
import Testing
@testable import agtermCore

@MainActor
struct HtmlOverlayTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}
    }

    let store = makeStore()
    let workspace: Workspace
    let session: Session

    init() throws {
        workspace = store.addWorkspace(name: "work")
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
    }

    private func page(_ file: String = "/tmp/a/report.html", grant: String? = nil) -> HtmlOverlay {
        HtmlOverlay(source: .file(path: file, grantRoot: grant))
    }

    private func web(_ url: String) throws -> HtmlOverlay {
        HtmlOverlay(source: .url(try #require(URL(string: url))))
    }

    private func split() {
        store.toggleSplit(session.id)
        session.surface = SpySurface(paneToken: "left")
        session.splitSurface = SpySurface(paneToken: "right")
    }

    private func recordReleases() -> () -> [UUID] {
        var released: [UUID] = []
        HtmlOverlayReleases.shared.onRelease = { released.append($0) }
        return { released }
    }

    @Test(arguments: [
        ("/a/b/report.html", String?.none, true),
        ("/a/b/report.html", "/a/b", true),
        ("/a/b/report.html", "/a", true),
        ("/a/b/report.html", "/a/b/report.html", false),
        ("/a/b/./report.html", "/a/b/report.html/", false),
        ("/a/bc/report.html", "/a/b", false),
        ("/x/report.html", "/a", false),
        ("relative/report.html", String?.none, false),
        ("/a/report.html", "relative", false),
    ])
    func grantContainment(_ file: String, _ grant: String?, _ valid: Bool) {
        #expect((HtmlOverlay.grantError(file: file, grantRoot: grant) == nil) == valid)
    }

    @Test(arguments: [
        ("/", false),
        ("/Users/me", false),
        ("/Users/me/", false),
        ("/Users/me/./", false),
        ("/Users/me/docs", true),
        ("/Users", true),
    ])
    func grantRefusesRootAndHome(_ grant: String, _ valid: Bool) {
        let error = HtmlOverlay.grantError(file: "/Users/me/docs/report.html", grantRoot: grant, home: "/Users/me")
        #expect((error == nil) == valid)
        if !valid { #expect(error == "cwd must not be / or the home directory") }
    }

    @Test(arguments: [
        ("file:///tmp/a/report.html", HtmlNavigationTarget.mainFrame, false, String?.none, HtmlNavigationDecision.cancel),
        ("file:///tmp/a/report.html", .mainFrame, false, "/tmp/a", .allow),
        ("file:///tmp/a/report.html#section", .mainFrame, true, "/tmp/a", .allow),
        ("file:///tmp/a/other.html", .mainFrame, true, nil, .cancel),
        ("about:blank", .mainFrame, false, nil, .allow),
        ("about:blank#section", .mainFrame, true, nil, .allow),
        ("file:///tmp/a/other.html", .mainFrame, true, "/tmp/a", .allow),
        ("file:///tmp/a/frame.html", .subframe, false, "/tmp/a", .allow),
        ("file:///etc/passwd", .mainFrame, true, "/tmp/a", .cancel),
        ("file:///tmp/ab/x.html", .subframe, false, "/tmp/a", .cancel),
        ("https://example.com/", .mainFrame, true, nil, .openExternal),
        ("http://example.com/", .mainFrame, true, nil, .openExternal),
        ("https://example.com/", .mainFrame, false, nil, .cancel),
        ("https://example.com/", .subframe, false, nil, .cancel),
        ("https://example.com/", .subframe, true, nil, .openExternal),
        ("https://example.com/", .newWindow, true, nil, .openExternal),
        ("https://example.com/", .newWindow, false, nil, .cancel),
        ("file:///tmp/a/report.html", .newWindow, true, nil, .cancel),
        ("about:blank", .subframe, false, nil, .allow),
        ("mailto:a@example.com", .mainFrame, true, nil, .cancel),
        ("x-custom://open", .mainFrame, true, nil, .cancel),
        ("data:text/html,hi", .mainFrame, false, nil, .cancel),
    ])
    func navigationPolicy(_ url: String, _ target: HtmlNavigationTarget, _ userActivated: Bool, _ grant: String?,
                          _ decision: HtmlNavigationDecision) throws {
        let action = HtmlNavigationAction(url: try #require(URL(string: url)), target: target, userActivated: userActivated)
        #expect(HtmlNavigationPolicy.decide(action, overlay: page(grant: grant)) == decision)
    }

    @Test(arguments: [
        ("http://localhost:5173/about", HtmlNavigationTarget.mainFrame, false, HtmlNavigationDecision.allow),
        ("http://LOCALHOST:5173/", .mainFrame, true, .allow),
        ("http://localhost:5174/", .mainFrame, false, .cancel),
        ("http://localhost:5174/", .mainFrame, true, .openExternal),
        ("https://localhost:5173/", .mainFrame, false, .cancel),
        ("https://example.com/", .mainFrame, true, .openExternal),
        ("https://example.com/", .mainFrame, false, .cancel),
        ("https://example.com/embed", .subframe, false, .allow),
        ("http://localhost:5173/", .newWindow, true, .openExternal),
        ("http://localhost:5173/", .newWindow, false, .cancel),
        ("about:blank", .mainFrame, false, .allow),
        ("about:srcdoc", .subframe, false, .allow),
        ("file:///tmp/a/report.html", .mainFrame, true, .cancel),
        ("file:///tmp/a/report.html", .subframe, false, .cancel),
        ("mailto:a@example.com", .mainFrame, true, .cancel),
    ])
    func urlPagePolicy(_ url: String, _ target: HtmlNavigationTarget, _ userActivated: Bool,
                       _ decision: HtmlNavigationDecision) throws {
        let action = HtmlNavigationAction(url: try #require(URL(string: url)), target: target, userActivated: userActivated)
        #expect(HtmlNavigationPolicy.decide(action, overlay: try web("http://localhost:5173/")) == decision)
    }

    @Test(arguments: [
        ("http://localhost:5173/about", HtmlNavigationTarget.mainFrame, false, HtmlNavigationDecision.allow),
        ("https://example.com/", .mainFrame, true, .allow),
        ("https://example.com/", .mainFrame, false, .allow),
        ("http://localhost:5174/", .mainFrame, false, .allow),
        ("https://example.com/embed", .subframe, false, .allow),
        ("https://example.com/", .newWindow, true, .openExternal),
        ("https://example.com/", .newWindow, false, .cancel),
        ("about:blank", .mainFrame, false, .allow),
        ("file:///tmp/a/report.html", .mainFrame, true, .cancel),
        ("file:///tmp/a/report.html", .subframe, false, .cancel),
        ("mailto:a@example.com", .mainFrame, true, .cancel),
        ("x-custom://open", .mainFrame, true, .cancel),
        ("data:text/html,hi", .mainFrame, false, .cancel),
    ])
    func browsingPagePolicy(_ url: String, _ target: HtmlNavigationTarget, _ userActivated: Bool,
                            _ decision: HtmlNavigationDecision) throws {
        let action = HtmlNavigationAction(url: try #require(URL(string: url)), target: target, userActivated: userActivated)
        let overlay = HtmlOverlay(source: .url(try #require(URL(string: "http://localhost:5173/"))), browse: true)
        #expect(HtmlNavigationPolicy.decide(action, overlay: overlay) == decision)
    }

    @Test(arguments: [
        ("http://127.0.0.1:8792/frame.html", HtmlNavigationTarget.subframe, false, HtmlNavigationDecision.allow),
        ("http://127.0.0.1:8792/next", .mainFrame, false, .allow),
        ("https://example.com/embed", .subframe, false, .cancel),
        ("https://example.com/embed", .subframe, true, .openExternal),
        ("http://localhost:8792/frame.html", .subframe, false, .cancel),
        ("http://127.0.0.1:8793/frame.html", .subframe, false, .cancel),
        ("https://example.com/", .mainFrame, false, .cancel),
        ("about:srcdoc", .subframe, false, .allow),
    ])
    func chromelessPagePolicyKeepsFramesOnItsOrigin(_ url: String, _ target: HtmlNavigationTarget, _ userActivated: Bool,
                                                    _ decision: HtmlNavigationDecision) throws {
        let action = HtmlNavigationAction(url: try #require(URL(string: url)), target: target, userActivated: userActivated)
        let overlay = HtmlOverlay(source: .url(try #require(URL(string: "http://127.0.0.1:8792/"))), chromeless: true)
        #expect(HtmlNavigationPolicy.decide(action, overlay: overlay) == decision)
    }

    @Test(arguments: [
        ("http://example.com/", "http://EXAMPLE.com:80/a", true),
        ("https://example.com/", "https://example.com:443/b", true),
        ("HTTPS://example.com/", "https://example.com/", true),
        ("http://example.com/", "https://example.com/", false),
        ("http://example.com/", "http://example.com:8080/", false),
        ("http://example.com/", "http://www.example.com/", false),
        ("http://[::1]:8080/", "http://[::1]:8080/x", true),
    ])
    func originEquality(_ lhs: String, _ rhs: String, _ same: Bool) throws {
        let left = try #require(URL(string: lhs).flatMap(HtmlOrigin.init))
        let right = try #require(URL(string: rhs).flatMap(HtmlOrigin.init))
        #expect((left == right) == same)
    }

    @Test(arguments: [
        ("http://localhost:5173/app?x=1", "http://localhost:5173"),
        ("https://Example.com:443/docs", "https://example.com"),
        ("http://example.com:8080/", "http://example.com:8080"),
        ("http://[::1]:8080/", "http://[::1]:8080"),
    ])
    func urlIdentityIsTheOrigin(_ address: String, _ identity: String) throws {
        var overlay = HtmlOverlay(source: .url(try #require(URL(string: address))))
        overlay.current = HtmlPageInfo(page: address, title: "agterm: enter your password", canGoBack: false, canGoForward: false)
        #expect(overlay.identity == identity)
    }

    @Test(arguments: [
        ("https://login.example/sso?next=1", "https://login.example"),
        ("http://localhost:5173/other", "http://localhost:5173"),
        ("about:blank", "about:blank"),
    ])
    func browsingIdentityIsTheOriginOfTheShownDocument(_ shown: String, _ identity: String) throws {
        var overlay = HtmlOverlay(source: .url(try #require(URL(string: "http://localhost:5173/app"))), browse: true)
        #expect(overlay.identity == "http://localhost:5173")
        overlay.current = HtmlPageInfo(page: shown, title: "https://bank.example", canGoBack: true, canGoForward: false)
        #expect(overlay.identity == identity)
    }

    @Test func anOrdinaryUrlPageKeepsNamingItsSourceOrigin() throws {
        var overlay = try web("http://localhost:5173/app")
        overlay.current = HtmlPageInfo(page: "https://login.example/sso", title: nil, canGoBack: true, canGoForward: false)
        #expect(overlay.identity == "http://localhost:5173")
    }

    @Test(arguments: [
        ("https://trusted.example@attacker.example/path", "https://attacker.example"),
        ("http://127.0.0.1:5173/", "http://127.0.0.1:5173"),
    ])
    func originNamesTheRealHost(_ address: String, _ origin: String) throws {
        #expect(HtmlSource.origin(of: try #require(URL(string: address))) == origin)
    }

    @Test func pageJavaScriptIsOffUnlessAsked() {
        let source = HtmlSource.file(path: "/a/r.html", grantRoot: nil)
        #expect(!HtmlOverlay(source: source).javascript)
        #expect(HtmlOverlay(source: source, javascript: true).javascript)
        #expect(!HtmlOverlay(source: source).persistent)
        #expect(HtmlOverlay(source: source, persistent: true).persistent)
    }

    @Test(arguments: [
        ("agterm-page://OWN/index.html", HtmlNavigationTarget.mainFrame, false, HtmlNavigationDecision.allow),
        ("agterm-page://own/sub/b.html", .subframe, false, .allow),
        ("agterm-page://\(UUID().uuidString)/index.html", .mainFrame, false, .cancel),
        ("file:///tmp/a/index.html", .mainFrame, false, .cancel),
        ("https://example.com/", .mainFrame, true, .openExternal),
        ("https://example.com/", .mainFrame, false, .cancel),
        ("about:blank", .mainFrame, false, .allow),
    ])
    func replicaPolicyAllowsOnlyItsOwnSchemeOrigin(_ url: String, _ target: HtmlNavigationTarget, _ userActivated: Bool,
                                                   _ expected: HtmlNavigationDecision) throws {
        let overlay = HtmlOverlay(source: .replica(path: "/origin/docs/index.html", content: .html), replicaOf: UUID())
        let resolved = url.replacingOccurrences(of: "OWN", with: overlay.id.uuidString)
            .replacingOccurrences(of: "own", with: overlay.id.uuidString.lowercased())
        let action = HtmlNavigationAction(url: try #require(URL(string: resolved)), target: target, userActivated: userActivated)
        #expect(HtmlNavigationPolicy.decide(action, overlay: overlay) == expected)
    }

    @Test func aReplicaIsNamedByItsFileAndReportsTheOriginPathAsReplica() throws {
        let origin = UUID()
        let overlay = HtmlOverlay(source: .replica(path: "/origin/docs/index.html", content: .html), replicaOf: origin)
        #expect(overlay.identity == "index.html")
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil) == nil)

        let node = try #require(store.htmlOverlayNodes(session, zoom: nil)?.first)
        #expect(node.file == "/origin/docs/index.html")
        #expect(node.cwd == nil)
        #expect(node.replica == true)
        #expect(node.remote == nil)
    }

    @Test func aLocalPageNodeOmitsTheRemoteFields() throws {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let node = try #require(store.htmlOverlayNodes(session, zoom: nil)?.first)
        let json = try #require(String(data: try JSONEncoder().encode(node), encoding: .utf8))
        #expect(!json.contains("\"remote\""))
        #expect(!json.contains("\"replica\""))

        let reservation = try JSONEncoder().encode(ControlRemoteOverlayNode(pane: nil, sizePercent: 60))
        #expect(!String(decoding: reservation, as: UTF8.self).contains("pageID"))
        let page = ControlRemoteOverlayNode(pane: "left", sizePercent: nil, pageID: "p1")
        #expect(try JSONDecoder().decode(ControlRemoteOverlayNode.self, from: JSONEncoder().encode(page)) == page)
    }

    @Test(arguments: [
        ("https://example.com/", HtmlNavigationTarget.mainFrame, true, HtmlNavigationDecision.openExternal),
        ("http://example.com/a", .newWindow, true, .openExternal),
        ("https://example.com/", .mainFrame, false, .cancel),
        ("https://example.com/", .subframe, false, .cancel),
        ("about:blank#intro", .mainFrame, true, .allow),
        ("file:///tmp/notes/other.md", .mainFrame, true, .cancel),
        ("javascript:alert(1)", .mainFrame, true, .cancel),
        ("data:text/html,x", .mainFrame, true, .cancel),
    ])
    func markdownPagePolicyHandsWebLinksOutAndKeepsEverythingElse(_ url: String, _ target: HtmlNavigationTarget,
                                                                  _ userActivated: Bool, _ expected: HtmlNavigationDecision) throws {
        let overlay = HtmlOverlay(source: .markdown(path: "/tmp/notes/readme.md"))
        let action = HtmlNavigationAction(url: try #require(URL(string: url)), target: target, userActivated: userActivated)
        #expect(HtmlNavigationPolicy.decide(action, overlay: overlay) == expected)
    }

    @Test(arguments: [
        ("https://example.com/", HtmlNavigationTarget.mainFrame, true, HtmlNavigationDecision.openExternal),
        ("https://example.com/", .mainFrame, false, .cancel),
        ("https://example.com/", .subframe, false, .cancel),
        ("about:blank", .mainFrame, false, .allow),
        ("file:///tmp/agdoc/other.html", .mainFrame, true, .cancel),
        ("file:///etc/passwd", .subframe, false, .cancel),
        ("javascript:alert(1)", .mainFrame, true, .cancel),
        ("data:text/html,x", .mainFrame, true, .cancel),
    ])
    func documentPagePolicyHandsWebLinksOutAndKeepsEverythingElse(_ url: String, _ target: HtmlNavigationTarget,
                                                                  _ userActivated: Bool, _ expected: HtmlNavigationDecision) throws {
        for source in [HtmlSource.document(path: "/tmp/agdoc/pr.html"), .replica(path: "/tmp/agdoc/pr.html", content: .document)] {
            let action = HtmlNavigationAction(url: try #require(URL(string: url)), target: target, userActivated: userActivated)
            #expect(HtmlNavigationPolicy.decide(action, overlay: HtmlOverlay(source: source)) == expected)
        }
    }

    @Test func aDocumentPageIsNamedByItsFileNeverTheTitle() {
        var overlay = HtmlOverlay(source: .document(path: "/tmp/agdoc/pr.html"))
        overlay.current = HtmlPageInfo(page: "/tmp/agdoc/pr.html", title: "enter your password", canGoBack: false, canGoForward: false)
        #expect(overlay.identity == "pr.html")
        #expect(overlay.source.kind == .document)
        #expect(HtmlSource.replica(path: "/tmp/agdoc/pr.html", content: .document).kind == .document)
    }

    @Test func aMarkdownPageIsNamedByItsFileNeverTheTitle() {
        var overlay = HtmlOverlay(source: .markdown(path: "/tmp/notes/readme.md"))
        overlay.current = HtmlPageInfo(page: "/tmp/notes/readme.md", title: "enter your password", canGoBack: false, canGoForward: false)
        #expect(overlay.identity == "readme.md")
        #expect(overlay.source.markdownPath == "/tmp/notes/readme.md")
        #expect(overlay.source.imagePath == nil)
    }

    @Test(arguments: [HtmlSource.markdown(path: "/tmp/notes/readme.md"), .replica(path: "/tmp/notes/readme.md", content: .markdown)])
    func aLinkPageIsNamedByTheFileItShows(_ source: HtmlSource) {
        var overlay = HtmlOverlay(source: source, navigation: true,
                                  markdownLinks: MarkdownLinkGrant(path: "/tmp/notes/readme.md", root: "/tmp/notes"))
        overlay.current = HtmlPageInfo(page: "/tmp/notes/sub/guide.md", title: "enter your password", canGoBack: true, canGoForward: false)
        #expect(overlay.identity == "guide.md")
    }

    @Test func aLinkPageKeepsItsOriginalForReadBack() {
        var overlay = HtmlOverlay(source: .markdown(path: "/tmp/notes/readme.md"), navigation: true,
                                  markdownLinks: MarkdownLinkGrant(path: "/tmp/notes/readme.md", root: "/tmp/notes"))
        overlay.current = HtmlPageInfo(page: "/tmp/notes/sub/guide.md", title: nil, canGoBack: true, canGoForward: false)
        #expect(overlay.source.markdownPath == "/tmp/notes/readme.md")
    }

    @Test func aMarkdownPageHasNavigationOnlyWithALinkGrant() {
        let grant = MarkdownLinkGrant(path: "/tmp/notes/readme.md", root: "/tmp/notes")
        #expect(HtmlOverlay(source: .markdown(path: "/tmp/notes/readme.md"), navigation: true, markdownLinks: grant).navigation)
        #expect(!HtmlOverlay(source: .markdown(path: "/tmp/notes/readme.md"), navigation: true).navigation)
        #expect(HtmlOverlay(source: .markdown(path: "/tmp/notes/readme.md"), navigation: false, markdownLinks: grant).markdownLinks == nil)
        #expect(HtmlOverlay(source: .file(path: "/tmp/a/x.html", grantRoot: nil), navigation: true).navigation)
    }

    @Test(arguments: [
        ("/tmp/notes/readme.md", HtmlNavigationTarget.mainFrame, false, HtmlNavigationDecision.allow),
        ("/tmp/notes/sub/guide.markdown", .mainFrame, true, .allow),
        ("/tmp/notes/a/../readme.md", .mainFrame, true, .allow),
        ("/tmp/notes/../other/x.md", .mainFrame, true, .cancel),
        ("/tmp/notes/%2e%2e/other/x.md", .mainFrame, true, .cancel),
        ("/tmp/other/x.md", .mainFrame, true, .cancel),
        ("/tmp/notes/notes.txt", .mainFrame, true, .cancel),
        ("/tmp/notes/sub/guide.md", .subframe, true, .cancel),
        ("/tmp/notes/sub/guide.md", .newWindow, true, .cancel),
    ])
    func aLinkPageLoadsOnlyItsOwnMarkdownInsideTheGrant(_ path: String, _ target: HtmlNavigationTarget,
                                                        _ userActivated: Bool, _ expected: HtmlNavigationDecision) throws {
        let grant = MarkdownLinkGrant(path: "/tmp/notes/readme.md", root: "/tmp/notes")
        let overlay = HtmlOverlay(source: .markdown(path: "/tmp/notes/readme.md"), navigation: true, markdownLinks: grant)
        let url = try #require(URL(string: "agterm-page://\(overlay.id.uuidString.lowercased())\(path)"))
        let action = HtmlNavigationAction(url: url, target: target, userActivated: userActivated)
        #expect(HtmlNavigationPolicy.decide(action, overlay: overlay) == expected)
    }

    @Test func aLinkPageRefusesAnotherPagesAddressAndAPageWithoutAGrant() throws {
        let grant = MarkdownLinkGrant(path: "/tmp/notes/readme.md", root: "/tmp/notes")
        let linked = HtmlOverlay(source: .markdown(path: "/tmp/notes/readme.md"), navigation: true, markdownLinks: grant)
        let plain = HtmlOverlay(source: .markdown(path: "/tmp/notes/readme.md"))
        let other = try #require(URL(string: "agterm-page://\(UUID().uuidString.lowercased())/tmp/notes/readme.md"))
        let own = try #require(URL(string: "agterm-page://\(plain.id.uuidString.lowercased())/tmp/notes/readme.md"))
        let web = try #require(URL(string: "https://example.com/x.md"))

        #expect(HtmlNavigationPolicy.decide(HtmlNavigationAction(url: other, target: .mainFrame, userActivated: true), overlay: linked) == .cancel)
        #expect(HtmlNavigationPolicy.decide(HtmlNavigationAction(url: own, target: .mainFrame, userActivated: true), overlay: plain) == .cancel)
        #expect(HtmlNavigationPolicy.decide(HtmlNavigationAction(url: web, target: .mainFrame, userActivated: true), overlay: linked) == .openExternal)
        #expect(HtmlNavigationPolicy.decide(HtmlNavigationAction(url: web, target: .mainFrame, userActivated: false), overlay: linked) == .cancel)
    }

    @Test(arguments: [
        ("about:blank", HtmlNavigationTarget.mainFrame, false, HtmlNavigationDecision.allow),
        ("about:blank", .mainFrame, true, .allow),
        ("about:blank", .subframe, false, .cancel),
        ("about:blank", .newWindow, true, .cancel),
        ("about:srcdoc", .mainFrame, false, .cancel),
        ("about:blank#x", .mainFrame, true, .cancel),
        ("https://example.com/", .mainFrame, true, .cancel),
        ("http://example.com/a", .newWindow, true, .cancel),
        ("file:///tmp/src/main.go", .mainFrame, true, .cancel),
        ("javascript:alert(1)", .mainFrame, true, .cancel),
        ("data:text/html,x", .mainFrame, true, .cancel),
    ])
    func textPagePolicyAllowsOnlyItsOwnBlankDocument(_ url: String, _ target: HtmlNavigationTarget,
                                                     _ userActivated: Bool, _ expected: HtmlNavigationDecision) throws {
        let overlay = HtmlOverlay(source: .text(path: "/tmp/src/main.go", line: 4))
        let action = HtmlNavigationAction(url: try #require(URL(string: url)), target: target, userActivated: userActivated)
        #expect(HtmlNavigationPolicy.decide(action, overlay: overlay) == expected)
    }

    @Test func aTextPageIsNamedByItsFileNeverTheTitle() {
        var overlay = HtmlOverlay(source: .text(path: "/tmp/src/main.go", line: 4))
        overlay.current = HtmlPageInfo(page: "/tmp/src/main.go", title: "enter your password", canGoBack: false, canGoForward: false)
        #expect(overlay.identity == "main.go")
        #expect(overlay.source.textPath == "/tmp/src/main.go")
        #expect(overlay.source.markdownPath == nil)
        #expect(HtmlSource.markdown(path: "/a.md").textPath == nil)
    }

    @Test func fileIdentityIsTheFileShownNeverTheTitle() {
        var overlay = HtmlOverlay(source: .file(path: "/a/docs/index.html", grantRoot: "/a/docs"))
        #expect(overlay.identity == "index.html")
        overlay.current = HtmlPageInfo(page: "/a/docs/b.html", title: "agterm: enter your password", canGoBack: true, canGoForward: false)
        #expect(overlay.identity == "b.html")
    }

    @Test(arguments: [
        ("http://localhost:5173/", true),
        ("https://example.com/docs?q=1#top", true),
        ("HTTPS://example.com", true),
        ("http://127.0.0.1:8000", true),
        ("http://[::1]:8080/", true),
        ("ftp://example.com/", false),
        ("file:///tmp/r.html", false),
        ("localhost:5173", false),
        ("/tmp/r.html", false),
        ("http://", false),
        ("javascript:alert(1)", false),
        ("", false),
    ])
    func webURLAcceptsOnlyAbsoluteHttpWithAHost(_ text: String, _ valid: Bool) {
        #expect((HtmlSource.webURL(text) != nil) == valid)
    }

    @Test(arguments: [
        ("http://127.0.0.1:8792/", true),
        ("https://127.0.0.1/app", true),
        ("http://[::1]:8792/", true),
        ("http://localhost:5173/", true),
        ("http://LOCALHOST/", true),
        ("http://127.0.0.2/", false),
        ("http://127.1/", false),
        ("http://2130706433/", false),
        ("http://0.0.0.0:8792/", false),
        ("http://[::ffff:127.0.0.1]/", false),
        ("http://localhost./", false),
        ("http://app.localhost/", false),
        ("http://localhost.example.com/", false),
        ("http://example.com/", false),
        ("ftp://127.0.0.1/", false),
        ("localhost:5173", false),
        ("", false),
    ])
    func isLoopbackMatchesOnlyTheExactLoopbackHosts(_ text: String, _ loopback: Bool) {
        #expect(HtmlSource.isLoopback(text) == loopback)
    }

    @Test func sessionWideOpenReplacesAHudAndClearsThePriorResult() throws {
        #expect(store.openOverlay(session.id, command: "true"))
        store.recordOverlayExit(session.id, code: 3)
        #expect(store.closeOverlay(session.id))
        #expect(store.openHud(session.id, command: "hud", spec: HudSpec(message: "x"), file: "/tmp/h",
                              size: HudPanelSize(widthPercent: 30, heightPercent: 10)))
        let generation = session.overlaySlotGeneration

        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: 60) == nil)
        #expect(session.htmlOverlayActive)
        #expect(!session.hudActive)
        #expect(session.overlayExitCode == nil)
        #expect(session.overlaySizePercent == 60)
        #expect(session.overlaySlotGeneration == generation + 1)
    }

    @Test func sessionWideOpenIsRefusedOverAProgramOrAPage() {
        #expect(store.openOverlay(session.id, command: "htop"))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == .alreadyOpen)
        #expect(store.closeOverlay(session.id))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == .alreadyOpen)
        #expect(store.openHtmlOverlay(UUID(), pane: nil, overlay: page(), sizePercent: nil) == .unknownSession)
    }

    @Test func aHudOverAPageIsRefused() {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(!store.openHud(session.id, command: "hud", spec: HudSpec(message: "x"), file: "/tmp/h",
                               size: HudPanelSize(widthPercent: 30, heightPercent: 10)))
        #expect(session.htmlOverlayActive)
    }

    @Test func paneOpenIsRefusedOverAProgramAPageOrAnUnrenderedPane() {
        split()
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop") == nil)
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page(), sizePercent: nil) == .alreadyOpen)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == .alreadyOpen)
        #expect(session.paneOverlayIsHtml(.right))
        #expect(!session.paneOverlayIsHtml(.left))
    }

    @Test func paneOpenClearsThePanesPriorResult() {
        split()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "true") == nil)
        store.recordPaneOverlayExit(session.id, pane: .right, code: 4)
        #expect(store.closePaneOverlay(session.id, pane: .right))
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(session.paneOverlayExitCode(.right) == nil)
    }

    @Test func openIsRefusedWhenAFollowingPaneBelongsToAPresenterWithoutPages() throws {
        let hub = PresentationHub(staleTimeout: 30)
        let presenter = Sink()
        store.presentationHub = hub
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: session.paneIdentity)
        let notice = try #require(ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):follower:1"))
        _ = ZmxLeadBook.shared.apply(notice, pane: session.paneIdentity)
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)

        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == .presenter)
        #expect(!session.overlayActive)
    }

    @Test func reloadBumpsOnlyTheRevisionAndResetsTheLoadState() throws {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let overlayID = try #require(session.htmlOverlay?.id)
        store.setHtmlLoadState(overlayID, state: .failed, error: "boom")
        let generation = session.overlaySlotGeneration

        #expect(store.reloadHtmlOverlay(session.id, pane: nil) == nil)
        #expect(session.htmlOverlay?.reloadRevision == 1)
        #expect(session.htmlOverlay?.loadState == .loading)
        #expect(session.htmlOverlay?.loadError == nil)
        #expect(session.htmlOverlay?.id == overlayID)
        #expect(session.overlaySlotGeneration == generation)
    }

    @Test func reloadOfTheCurrentPageKeepsWhatTheUserNavigatedTo() throws {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(grant: "/tmp/a"), sizePercent: nil) == nil)
        let overlayID = try #require(session.htmlOverlay?.id)
        let info = HtmlPageInfo(page: "/tmp/a/b.html", title: "B", canGoBack: true, canGoForward: false)
        store.setHtmlPage(overlayID, info)

        #expect(store.reloadHtmlOverlay(session.id, pane: nil, target: .current) == nil)
        #expect(session.htmlOverlay?.reloadTarget == .current)
        #expect(session.htmlOverlay?.current == info)
        #expect(store.reloadHtmlOverlay(session.id, pane: nil) == nil)
        #expect(session.htmlOverlay?.reloadTarget == .original)
        #expect(session.htmlOverlay?.current == nil)
        #expect(session.htmlOverlay?.reloadRevision == 2)
    }

    @Test func aPageCommandIsRefusedOnAnEmptySlotOrAProgram() {
        split()
        #expect(store.htmlOverlayCommandFailure(session.id, pane: nil) == .noOverlay)
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop") == nil)
        #expect(store.htmlOverlayCommandFailure(session.id, pane: .left) == .notHtml)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(store.htmlOverlayCommandFailure(session.id, pane: .right) == nil)
    }

    @Test func reloadIsRefusedOnAnEmptySlotOrAProgram() {
        split()
        #expect(store.reloadHtmlOverlay(session.id, pane: nil) == .noOverlay)
        #expect(store.reloadHtmlOverlay(session.id, pane: .left) == .noOverlay)
        #expect(store.openOverlay(session.id, command: "htop"))
        #expect(store.reloadHtmlOverlay(session.id, pane: nil) == .notHtml)
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "htop") == nil)
        #expect(store.reloadHtmlOverlay(session.id, pane: .left) == .notHtml)
        #expect(store.reloadHtmlOverlay(UUID(), pane: nil) == .unknownSession)
    }

    @Test func loadStateReachesTheSlotByOccupantID() throws {
        split()
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        let overlayID = try #require(session.paneOverlay(.right)?.html?.id)

        store.setHtmlLoadState(overlayID, state: .loaded, error: nil)
        #expect(session.paneOverlay(.right)?.html?.loadState == .loaded)
        store.setHtmlLoadState(UUID(), state: .failed, error: "stray")
        #expect(session.paneOverlay(.right)?.html?.loadState == .loaded)
    }

    @Test func loadStateReachesASoftClosedSession() throws {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let overlayID = try #require(session.htmlOverlay?.id)
        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(store.session(withID: session.id) == nil)

        store.setHtmlLoadState(overlayID, state: .failed, error: "gone")
        #expect(session.htmlOverlay?.loadState == .failed)
        #expect(session.htmlOverlay?.loadError == "gone")
    }

    @Test func swapKeepsEachPageWithItsIdentity() throws {
        split()
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page("/tmp/l.html"), sizePercent: nil) == nil)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page("/tmp/r.html"), sizePercent: nil) == nil)
        let left = try #require(session.paneOverlay(.left)?.html)
        let right = try #require(session.paneOverlay(.right)?.html)

        #expect(store.swapPanes(session.id) == nil)
        #expect(session.paneOverlay(.left)?.html == right)
        #expect(session.paneOverlay(.right)?.html == left)

        store.setHtmlLoadState(right.id, state: .loaded, error: nil)
        #expect(session.paneOverlay(.left)?.html?.loadState == .loaded)
        #expect(store.reloadHtmlOverlay(session.id, pane: .left) == nil)
        #expect(session.paneOverlay(.left)?.html?.reloadRevision == 1)
    }

    @Test func promotionMovesTheRightPageIntoTheLeftSlot() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        let right = try #require(session.paneOverlay(.right)?.html)

        store.closePrimaryPane(session.id)
        #expect(session.paneOverlay(.left)?.html?.id == right.id)
        #expect(session.paneOverlay(.right) == nil)
        #expect(released().isEmpty)

        #expect(store.closePaneOverlay(session.id, pane: .left))
        #expect(released() == [right.id])
    }

    @Test func dropUnrealizedPaneOverlaysKeepsAPage() {
        split()
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        session.isSplit = false
        session.splitFocused = false
        session.dropUnrealizedPaneOverlays()
        #expect(session.paneOverlayIsHtml(.right))
        session.isSplit = true
        #expect(session.paneOverlayIsHtml(.right))
    }

    @Test func explicitClosesReleaseEachPageOnce() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let wide = try #require(session.htmlOverlay?.id)
        #expect(store.closeOverlay(session.id))
        #expect(!store.closeOverlay(session.id))
        #expect(session.htmlOverlay == nil)

        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page(), sizePercent: nil) == nil)
        let left = try #require(session.paneOverlay(.left)?.html?.id)
        #expect(store.closePaneOverlay(session.id, pane: .left))
        #expect(!store.closePaneOverlay(session.id, pane: .left))

        #expect(released() == [wide, left])
    }

    @Test func closingAProgramPaneKeepsItsExitCode() {
        split()
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "true") == nil)
        store.recordPaneOverlayExit(session.id, pane: .right, code: 2)
        #expect(store.closePaneOverlay(session.id, pane: .right))
        #expect(session.paneOverlayExitCode(.right) == 2)
    }

    @Test func sessionCloseReleasesBothKindsOfPageOnce() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page(), sizePercent: nil) == nil)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let ids = [try #require(session.htmlOverlay?.id), try #require(session.paneOverlay(.left)?.html?.id)]

        store.closeSession(session.id)
        #expect(Set(released()) == Set(ids))
        #expect(released().count == 2)
    }

    @Test func workspaceRemovalReleasesThePage() throws {
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let id = try #require(session.htmlOverlay?.id)
        store.addWorkspace(name: "other")
        store.removeWorkspace(workspace.id)
        #expect(released() == [id])
    }

    @Test func finalizingASoftCloseReleasesThePageOnce() throws {
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        let id = try #require(session.htmlOverlay?.id)
        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(released().isEmpty)
        store.finalizeAllPendingCloses()
        #expect(released() == [id])
    }

    @Test func splitCloseReleasesTheSplitPanesPage() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        let id = try #require(session.paneOverlay(.right)?.html?.id)
        store.closeSplit(session.id)
        #expect(released() == [id])
    }

    @Test func aSessionWidePageCoversWithoutBeingAProgram() {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(session.coverOverlayActive)
        #expect(!session.programOverlayActive)
        #expect(session.topmostSurface == nil)
        #expect(session.focusTarget(wantSplit: false) == nil)
        #expect(session.htmlCovers(nil))
        #expect(!session.htmlCovers(.left))
    }

    @Test func aPanePageLeavesNoTerminalFocusTarget() {
        split()
        session.splitFocused = true
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page(), sizePercent: nil) == nil)
        #expect(session.topmostSurface == nil)
        #expect(session.focusTarget(wantSplit: true) == nil)
        #expect(session.htmlCovers(.right))
    }

    @Test func zoomHasNoTargetUnderASessionWidePage() {
        store.selectSession(session.id)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(TerminalZoomController.resolveTarget(store: store) == nil)
        #expect(!TerminalZoomSurface.overlay.isAvailable(in: session))
        #expect(!TerminalZoomSurface.primary.isVisible(in: session))
    }

    @Test(arguments: [OverlayPane.left, .right])
    func zoomHasNoTargetUnderAPageOnTheFocusedPane(_ pane: OverlayPane) {
        split()
        store.selectSession(session.id)
        session.splitFocused = pane == .right
        #expect(store.openHtmlOverlay(session.id, pane: pane, overlay: page(), sizePercent: nil) == nil)
        #expect(TerminalZoomController.resolveTarget(store: store) == nil)
        #expect(!pane.zoomSurface.isAvailable(in: session))
    }

    @Test(arguments: [
        (StatusPane?.none, true), (.left, true), (.right, true), (.scratch, false),
    ])
    func aSessionWidePageHidesBothSplitTerminals(_ pane: StatusPane?, _ hidden: Bool) {
        split()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: nil) == nil)
        #expect(session.htmlHidesTerminal(pane) == hidden)
    }

    @Test(arguments: [
        (OverlayPane.left, StatusPane?.none, true), (.left, .left, true), (.left, .right, false),
        (.right, nil, false), (.right, .right, true), (.right, .scratch, false),
    ])
    func aPanePageHidesOnlyItsOwnTerminal(_ slot: OverlayPane, _ pane: StatusPane?, _ hidden: Bool) {
        split()
        #expect(store.openHtmlOverlay(session.id, pane: slot, overlay: page(), sizePercent: nil) == nil)
        #expect(session.htmlHidesTerminal(pane) == hidden)
    }

    @Test(arguments: [Int?.none, 70], [true, false])
    func aSessionWidePageHidesTheScratchOnlyWhileItIsShown(_ size: Int?, _ shown: Bool) {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: size) == nil)
        session.scratchActive = shown
        #expect(session.htmlHidesTerminal(.scratch) == shown)
    }

    @Test func noPageHidesNoTerminal() {
        split()
        #expect(StatusPane.allCases.allSatisfy { !session.htmlHidesTerminal($0) })
        #expect(!session.htmlHidesTerminal(nil))
    }

    @Test(arguments: [
        ("increase_font_size:1", 1.0, 1.15), ("increase_font_size:1", 2.5, 3.0), ("increase_font_size:1", 3.0, 3.0),
        ("increase_font_size:1", 1.1, 1.15), ("decrease_font_size:1", 1.0, 0.85), ("decrease_font_size:1", 0.5, 0.5),
        ("decrease_font_size:1", 1.1, 1.0), ("reset_font_size", 2.0, 1.0),
    ])
    func zoomWalksTheLadder(_ action: String, _ from: Double, _ to: Double) {
        #expect(HtmlZoom.applying(fontAction: action, to: from) == to)
    }

    @Test func zoomIgnoresAnythingButAFontSizeAction() {
        #expect(HtmlZoom.applying(fontAction: "paste_from_clipboard", to: 1) == nil)
    }

    @Test(arguments: [(Double?.none, 1.0), (1.5, 1.5), (0.1, 0.5), (9, 3.0), (.nan, 1.0), (.infinity, 1.0)])
    func zoomResolvesAStoredFactorIntoRange(_ stored: Double?, _ resolved: Double) {
        #expect(HtmlZoom.resolve(stored) == resolved)
    }

    @Test func treeReportsAPageAsAnOverlay() throws {
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page(), sizePercent: 40) == nil)
        let node = try #require(store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
        #expect(node.overlay)
        #expect(node.overlaySizePercent == 40)
    }

    @Test func aPageIsFoundAndClosedByItsIdentityAfterASwap() throws {
        split()
        let released = recordReleases()
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page(), sizePercent: nil) == nil)
        let id = try #require(session.paneOverlay(.left)?.html?.id)
        #expect(store.swapPanes(session.id) == nil)

        let slot = try #require(store.htmlOverlaySlot(id))
        #expect(slot.session === session)
        #expect(slot.pane == .right)
        #expect(store.closeHtmlOverlay(id))
        #expect(session.paneOverlay(.right) == nil)
        #expect(released() == [id])
        #expect(!store.closeHtmlOverlay(id))
        #expect(store.htmlOverlaySlot(id) == nil)
    }

    @Test func theTopmostPageFollowsWhatCoversTheFocusedPane() throws {
        split()
        session.splitFocused = false
        #expect(session.topmostHtmlOverlay == nil)
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page("/tmp/r.html"), sizePercent: nil) == nil)
        #expect(session.topmostHtmlOverlay == nil)
        session.splitFocused = true
        #expect(session.topmostHtmlOverlay?.source == .file(path: "/tmp/r.html", grantRoot: nil))
        session.scratchActive = true
        #expect(session.topmostHtmlOverlay == nil)
        session.scratchActive = false
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page("/tmp/w.html"), sizePercent: nil) == nil)
        #expect(session.topmostHtmlOverlay?.source == .file(path: "/tmp/w.html", grantRoot: nil))
    }

    @Test func theThemeStylesheetYieldsToAnyPageRule() {
        let theme = HtmlOverlayTheme(background: "#102030", foreground: "#e0e0e0", dark: true)
        #expect(theme.stylesheet(themed: true)
            == ":where(html) { color-scheme: dark; color: #e0e0e0; --agterm-background: #102030; --agterm-foreground: #e0e0e0; }")
        #expect(theme.background == "#102030")
        #expect(theme.script(themed: true).contains(theme.stylesheet(themed: true)))
        #expect(theme.script(themed: true).contains("agterm-theme"))
    }

    @Test func aUrlPageGetsTheVariablesWithoutTheLook() {
        let theme = HtmlOverlayTheme(background: "#102030", foreground: "#e0e0e0", dark: true, palette: palette())
        let css = theme.stylesheet(themed: false)
        #expect(!css.contains("color-scheme"))
        #expect(!css.contains(" color:"))
        #expect(css.hasPrefix(":where(html) { --agterm-background: #102030; --agterm-foreground: #e0e0e0; --agterm-color-0: #000000;"))
        #expect(theme.script(themed: false).contains(css))
    }

    @Test func thePaletteKeepsItsAnsiSlots() {
        let css = HtmlOverlayTheme(background: "#102030", foreground: "#e0e0e0", dark: true, palette: palette())
            .stylesheet(themed: true)
        #expect(css.contains("--agterm-color-1: #010000; "))
        #expect(css.contains("--agterm-color-15: #0f0000; }"))
    }

    @Test func anInvalidPaletteEntryOmitsOnlyItsOwnSlot() {
        var entries = palette()
        entries[3] = "red; } body { display: none"
        let css = HtmlOverlayTheme(background: "#102030", foreground: "#e0e0e0", dark: true, palette: entries)
            .stylesheet(themed: true)
        #expect(!css.contains("--agterm-color-3:"))
        #expect(!css.contains("display"))
        #expect(css.contains("--agterm-color-4: #040000;"))
    }

    @Test(arguments: [0, 8, 17])
    func aPaletteOfTheWrongSizeOmitsEverySlot(_ count: Int) {
        let css = HtmlOverlayTheme(background: "#102030", foreground: "#e0e0e0", dark: true,
                                   palette: Array(palette(count).prefix(count)))
            .stylesheet(themed: true)
        #expect(!css.contains("--agterm-color-"))
    }

    private func palette(_ count: Int = 16) -> [String] {
        (0..<count).map { String(format: "#%02x0000", $0) }
    }

    @Test func aMalformedThemeColorFallsBackToAPlainPair() {
        let theme = HtmlOverlayTheme(background: "red; } body { display: none", foreground: "#ffffff", dark: false)
        #expect(theme.background == "#ffffff")
        #expect(theme.foreground == "#1e1e1e")
        #expect(!theme.stylesheet(themed: true).contains("display"))
    }

    private final class TreeEvents {
        var count = 0
    }

    private func logStore() throws -> (store: AppStore, session: Session, events: TreeEvents) {
        let events = TreeEvents()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir),
                             controlEventSink: { if $0.kind == .treeChanged { events.count += 1 } }, paneFinalizer: nil)
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        return (store, session, events)
    }

    private func logPage(follow: Bool = true) -> HtmlOverlay {
        HtmlOverlay(source: .text(path: "/tmp/app.log", line: nil), textLog: TextLog(tail: 50, follow: follow))
    }

    @Test func aLogPageStartsWithTheRequestedFollowStateAndOtherPagesHaveNone() {
        #expect(logPage(follow: true).logState == TextLogState(following: true))
        #expect(logPage(follow: false).logState == TextLogState(following: false))
        #expect(HtmlOverlay(source: .text(path: "/tmp/a.txt", line: nil)).logState == nil)
    }

    @Test(arguments: [(ControlToggleMode.on, false, true), (.off, true, false), (.toggle, true, false), (.toggle, false, true)])
    func followModeSetsTheLogPage(mode: ControlToggleMode, from: Bool, to: Bool) throws {
        let (store, session, events) = try logStore()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: logPage(follow: from), sizePercent: nil) == nil)
        let opened = events.count

        #expect(store.setTextLogFollowing(session.id, pane: nil, mode: mode) == .success(to))

        #expect(session.htmlOverlay?.logState?.following == to)
        #expect(events.count == opened + 1)
    }

    @Test func followModeThatChangesNothingEmitsNothing() throws {
        let (store, session, events) = try logStore()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: logPage(follow: true), sizePercent: nil) == nil)
        let opened = events.count

        #expect(store.setTextLogFollowing(session.id, pane: nil, mode: .on) == .success(true))

        #expect(events.count == opened)
    }

    @Test func followModeRefusesEverythingButALogPage() throws {
        let (store, session, _) = try logStore()
        #expect(store.setTextLogFollowing(session.id, pane: nil, mode: .on) == .failure(.page(.noOverlay)))
        #expect(store.setTextLogFollowing(UUID(), pane: nil, mode: .on) == .failure(.page(.unknownSession)))

        let text = HtmlOverlay(source: .text(path: "/tmp/a.txt", line: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: text, sizePercent: nil) == nil)
        #expect(store.setTextLogFollowing(session.id, pane: nil, mode: .on) == .failure(.notLog))
        #expect(TextLogFollowFailure.notLog.message == "no log page")
        #expect(store.closeOverlay(session.id))

        #expect(store.openOverlay(session.id, command: "less"))
        #expect(store.setTextLogFollowing(session.id, pane: nil, mode: .on) == .failure(.page(.notHtml)))
    }

    @Test func aScrollReportedFollowChangeEmitsOnlyWhenItChanges() throws {
        let (store, session, events) = try logStore()
        let page = logPage(follow: true)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        let opened = events.count

        store.setTextLogFollowing(page.id, following: false)
        store.setTextLogFollowing(page.id, following: false)

        #expect(session.htmlOverlay?.logState?.following == false)
        #expect(events.count == opened + 1)
    }

    @Test func aReportIsWrittenWithNoEventAndKeepsFollowing() throws {
        let (store, session, events) = try logStore()
        let page = logPage(follow: false)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        let opened = events.count
        let report = TextLogReport(lines: 12, clipped: true, waiting: false, unreadable: true)

        store.setTextLogReport(page.id, report)

        #expect(session.htmlOverlay?.logState == TextLogState(following: false, report: report))
        #expect(events.count == opened)
    }

    @Test func aReportForAPageThatIsNotALogPageIsIgnored() throws {
        let (store, session, _) = try logStore()
        let text = HtmlOverlay(source: .text(path: "/tmp/a.txt", line: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: text, sizePercent: nil) == nil)

        store.setTextLogReport(text.id, TextLogReport(lines: 3))
        store.setTextLogFollowing(text.id, following: true)

        #expect(session.htmlOverlay?.logState == nil)
    }

    @Test func aLogPageNodeReportsItsLimitAndLiveState() throws {
        let (store, session, _) = try logStore()
        let page = logPage(follow: true)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        store.setTextLogReport(page.id, TextLogReport(lines: 7, clipped: true, waiting: false, unreadable: true))

        let text = try #require(store.htmlOverlayNodes(session, zoom: nil)?.first?.text)

        #expect(text == ControlTextOverlayNode(file: "/tmp/app.log", language: nil, line: nil, tail: 50, following: true,
                                               lines: 7, clipped: true, waiting: false, unreadable: true))
    }

    @Test func aPlainTextPageNodeOmitsTheLogFields() throws {
        let (store, session, _) = try logStore()
        let text = HtmlOverlay(source: .text(path: "/tmp/a.txt", line: 3))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: text, sizePercent: nil) == nil)

        let node = try #require(store.htmlOverlayNodes(session, zoom: nil)?.first?.text)
        let json = try #require(String(data: try JSONEncoder().encode(node), encoding: .utf8))

        for field in ["tail", "following", "lines", "clipped", "waiting", "unreadable", "search"] {
            #expect(!json.contains("\"\(field)\""))
        }
    }

    @Test func aQuerySetOrClosedBumpsTheRevisionAndEmitsOnlyOnAChange() throws {
        let (store, session, events) = try logStore()
        let page = logPage()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        let opened = events.count

        store.setTextSearch(page.id, query: "error")
        store.setTextSearch(page.id, query: "error")
        #expect(session.htmlOverlay?.textSearch == TextSearch(query: "error"))
        #expect(session.htmlOverlay?.searchRevision == 1)
        #expect(events.count == opened + 1)

        store.setTextSearch(page.id, query: "")
        store.setTextSearch(page.id, query: "")
        #expect(session.htmlOverlay?.textSearch == nil)
        #expect(session.htmlOverlay?.searchRevision == 2)
        #expect(events.count == opened + 2)
    }

    @Test func aReportIsKeptOnlyForTheCurrentRevisionAndEmitsNothing() throws {
        let (store, session, events) = try logStore()
        let page = HtmlOverlay(source: .text(path: "/tmp/a.txt", line: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        store.setTextSearch(page.id, query: "a")
        store.setTextSearch(page.id, query: "ab")
        let set = events.count

        store.setTextSearchReport(page.id, revision: 1, query: "a", matches: 9, current: 4)
        #expect(session.htmlOverlay?.textSearch == TextSearch(query: "ab"))
        store.setTextSearchReport(page.id, revision: 2, query: "abc", matches: 7, current: 2)
        #expect(session.htmlOverlay?.textSearch == TextSearch(query: "ab"))

        store.setTextSearchReport(page.id, revision: 2, query: "ab", matches: 3, current: 1)
        #expect(session.htmlOverlay?.textSearch == TextSearch(query: "ab", matches: 3, current: 1))
        #expect(events.count == set)
    }

    @Test func aClosedSearchDropsALateReport() throws {
        let (store, session, _) = try logStore()
        let page = HtmlOverlay(source: .text(path: "/tmp/a.txt", line: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        store.setTextSearch(page.id, query: "a")
        store.setTextSearch(page.id, query: "")

        store.setTextSearchReport(page.id, revision: 2, query: "a", matches: 1, current: 1)

        #expect(session.htmlOverlay?.textSearch == nil)
    }

    @Test func aSearchAddressesOnlyALocalTextPage() throws {
        let (store, session, _) = try logStore()
        #expect(store.textSearchPage(session.id, pane: nil) == .failure(.page(.noOverlay)))
        #expect(store.textSearchPage(UUID(), pane: nil) == .failure(.page(.unknownSession)))

        let markdown = HtmlOverlay(source: .markdown(path: "/tmp/a.md"))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: markdown, sizePercent: nil) == nil)
        #expect(store.textSearchPage(session.id, pane: nil) == .failure(.notText))
        store.setTextSearch(markdown.id, query: "a")
        #expect(session.htmlOverlay?.textSearch == nil)
        #expect(store.closeOverlay(session.id))

        let replica = HtmlOverlay(source: .replica(path: "/tmp/a.txt", content: .text(line: nil)), replicaOf: UUID())
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: replica, sizePercent: nil) == nil)
        #expect(store.textSearchPage(session.id, pane: nil) == .failure(.notText))
        #expect(store.closeOverlay(session.id))

        let log = logPage()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: log, sizePercent: nil) == nil)
        #expect(store.textSearchPage(session.id, pane: nil).map(\.id) == .success(log.id))
        #expect(store.closeOverlay(session.id))

        #expect(store.openOverlay(session.id, command: "less"))
        #expect(store.textSearchPage(session.id, pane: nil) == .failure(.page(.notHtml)))
        #expect(TextSearchFailure.notText.message == "no text page")
    }

    @Test func aTextPageNodeReportsItsSearch() throws {
        let (store, session, _) = try logStore()
        let page = HtmlOverlay(source: .text(path: "/tmp/a.txt", line: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        store.setTextSearch(page.id, query: "main()")
        store.setTextSearchReport(page.id, revision: 1, query: "main()", matches: 4, current: 2)

        let text = try #require(store.htmlOverlayNodes(session, zoom: nil)?.first?.text)

        #expect(text.search == ControlTextSearchNode(query: "main()", matches: 4, current: 2))
    }

    @Test func aChangesReportIsKeptClearedAndEmitsNothing() throws {
        let (store, session, events) = try logStore()
        let page = HtmlOverlay(source: .text(path: "/tmp/a.diff", line: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        let opened = events.count

        store.setTextChangesReport(page.id, changes: TextChanges(count: 7, current: 3))
        #expect(session.htmlOverlay?.textChanges == TextChanges(count: 7, current: 3))
        store.setTextChangesReport(page.id, changes: nil)
        #expect(session.htmlOverlay?.textChanges == nil)
        #expect(events.count == opened)
    }

    @Test func aChangesStepAddressesOnlyALocalDiffPage() throws {
        let (store, session, _) = try logStore()
        #expect(store.textChangesPage(session.id, pane: nil) == .failure(.page(.noOverlay)))

        let plain = HtmlOverlay(source: .text(path: "/tmp/a.txt", line: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: plain, sizePercent: nil) == nil)
        #expect(store.textChangesPage(session.id, pane: nil) == .failure(.notDiff))
        #expect(store.closeOverlay(session.id))

        let markdown = HtmlOverlay(source: .markdown(path: "/tmp/a.md"))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: markdown, sizePercent: nil) == nil)
        #expect(store.textChangesPage(session.id, pane: nil) == .failure(.notDiff))
        store.setTextChangesReport(markdown.id, changes: TextChanges(count: 1, current: 0))
        #expect(session.htmlOverlay?.textChanges == nil)
        #expect(store.closeOverlay(session.id))

        let patch = HtmlOverlay(source: .text(path: "/tmp/a.patch", line: 3))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: patch, sizePercent: nil) == nil)
        #expect(store.textChangesPage(session.id, pane: nil).map(\.id) == .success(patch.id))
        #expect(store.closeOverlay(session.id))

        #expect(store.openOverlay(session.id, command: "less"))
        #expect(store.textChangesPage(session.id, pane: nil) == .failure(.page(.notHtml)))
        #expect(TextChangesFailure.notDiff.message == "no diff page")
    }

    @Test func aTextPageNodeReportsItsChangesOnlyOnceReported() throws {
        let (store, session, _) = try logStore()
        let page = HtmlOverlay(source: .text(path: "/tmp/a.diff", line: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        let before = try #require(store.htmlOverlayNodes(session, zoom: nil)?.first?.text)
        let json = String(data: try JSONEncoder().encode(before), encoding: .utf8) ?? ""
        #expect(!json.contains("changes"))

        store.setTextChangesReport(page.id, changes: TextChanges(count: 11, current: 2))
        let text = try #require(store.htmlOverlayNodes(session, zoom: nil)?.first?.text)

        #expect(text.changes == ControlTextChangesNode(count: 11, current: 2))
    }
}
