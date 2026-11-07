import GhosttyKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class GhosttySurfaceViewInputTests: XCTestCase {
    private var savedOpener = LinkOpener()

    private final class Followed {
        var opened: [URL] = []
        var revealed: [URL] = []
        var overlaid: [(URL, UUID, Int?)] = []
        var images: [(URL, UUID)] = []
        var markdowns: [(URL, UUID, Int?)] = []
        var texts: [LinkPolicy.TextLink] = []
        var documents: [(URL, UUID, Int?)] = []
    }

    private final class ExistsProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [(String, Bool)] = []
        let existing: Set<String>

        init(_ existing: Set<String>) { self.existing = existing }

        func check(_ path: String) -> Bool {
            lock.withLock { asked.append((path, Thread.isMainThread)) }
            return existing.contains(path)
        }

        var paths: [String] { lock.withLock { asked.map(\.0) } }
        var onMain: [Bool] { lock.withLock { asked.map(\.1) } }
    }

    private func recordLinks(mode: LinkOpenMode, overlayOpens: Bool) -> Followed {
        let followed = Followed()
        LinkOpener.shared.mode = { mode }
        LinkOpener.shared.open = { followed.opened.append($0) }
        LinkOpener.shared.reveal = { followed.revealed.append($0) }
        LinkOpener.shared.overlay = { url, session, percent in
            followed.overlaid.append((url, session, percent))
            return overlayOpens
        }
        LinkOpener.shared.image = { url, session, done in
            followed.images.append((url, session))
            done(overlayOpens)
        }
        LinkOpener.shared.markdown = { url, session, percent, done in
            followed.markdowns.append((url, session, percent))
            done(overlayOpens)
        }
        LinkOpener.shared.text = { link, done in
            followed.texts.append(link)
            done(overlayOpens)
        }
        LinkOpener.shared.document = { url, session, percent, done in
            followed.documents.append((url, session, percent))
            done(overlayOpens)
        }
        LinkOpener.shared.exists = { _ in false }
        return followed
    }

    private func bareSurface() -> GhosttySurfaceView {
        GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
    }

    func testEachSurfaceKindNamesItsLinkClickOrigin() {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        pane.focusSession = session
        let scratch = bareSurface()
        scratch.watermarkSession = session
        scratch.focusSession = session
        let program = bareSurface()
        program.focusSession = session
        let hud = bareSurface()
        hud.focusSession = session
        hud.hudBodyFile = "/tmp/agterm-test-hud-body-missing"
        let quick = bareSurface()

        XCTAssertEqual(pane.linkClickOrigin, .pane(session.id))
        XCTAssertEqual(scratch.linkClickOrigin, .scratch(session.id))
        XCTAssertEqual(program.linkClickOrigin, .programOverlay)
        XCTAssertEqual(hud.linkClickOrigin, .hud)
        XCTAssertEqual(quick.linkClickOrigin, .quick)
        hud.hudBodyFile = nil
        let remote = bareSurface()
        let remoteSession = Session(initialCwd: NSTemporaryDirectory(), remoteHost: "buildbox")
        remote.session = remoteSession
        XCTAssertEqual(remote.linkClickOrigin, .remotePane(remoteSession.id))
    }

    func testAPaneImagePathShowsOverTheSessionAndRevealsWhenItCannot() {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        let url = URL(fileURLWithPath: "/tmp/shot.png", isDirectory: false)

        let shown = recordLinks(mode: .browser, overlayOpens: true)
        pane.openLink("/tmp/shot.png", intent: .normal)
        XCTAssertEqual(shown.images.map(\.0), [url])
        XCTAssertEqual(shown.images.map(\.1), [session.id])
        XCTAssertTrue(shown.revealed.isEmpty)

        let refused = recordLinks(mode: .overlay, overlayOpens: false)
        pane.openLink("/tmp/shot.png", intent: .normal)
        XCTAssertEqual(refused.images.count, 1)
        XCTAssertEqual(refused.revealed, [url])
    }

    func testAPaneMarkdownPathRendersAtItsModeSizeAndRevealsWhenItCannot() {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        let url = URL(fileURLWithPath: "/tmp/notes.md", isDirectory: false)

        let shown = recordLinks(mode: .overlay75, overlayOpens: true)
        pane.openLink("/tmp/notes.md", intent: .normal)
        XCTAssertEqual(shown.markdowns.map(\.0), [url])
        XCTAssertEqual(shown.markdowns.map(\.1), [session.id])
        XCTAssertEqual(shown.markdowns.map(\.2), [75])
        XCTAssertTrue(shown.revealed.isEmpty)

        let browser = recordLinks(mode: .overlay, overlayOpens: true)
        pane.openLink("/tmp/notes.md", intent: .browser)
        XCTAssertEqual(browser.markdowns.map(\.2), [95])

        let refused = recordLinks(mode: .overlay, overlayOpens: false)
        pane.openLink("file:///tmp/notes.md", intent: .normal)
        XCTAssertEqual(refused.markdowns.count, 1)
        XCTAssertEqual(refused.revealed, [url])
    }

    func testAPaneHtmlPathOpensAtItsModeSizeAndRevealsWhenItCannot() {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        let url = URL(fileURLWithPath: "/tmp/pr.html", isDirectory: false)

        let shown = recordLinks(mode: .overlay75, overlayOpens: true)
        pane.openLink("/tmp/pr.html", intent: .normal)
        XCTAssertEqual(shown.documents.map(\.0), [url])
        XCTAssertEqual(shown.documents.map(\.1), [session.id])
        XCTAssertEqual(shown.documents.map(\.2), [75])
        XCTAssertTrue(shown.revealed.isEmpty)

        let refused = recordLinks(mode: .overlay, overlayOpens: false)
        pane.openLink("file:///tmp/pr.html", intent: .normal)
        XCTAssertEqual(refused.documents.count, 1)
        XCTAssertEqual(refused.revealed, [url])
    }

    func testAPaneTextPathOpensAtItsModeSizeAndRevealsWhenItCannot() {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        let url = URL(fileURLWithPath: "/tmp/main.go", isDirectory: false)

        let shown = recordLinks(mode: .overlay75, overlayOpens: true)
        pane.openLink("/tmp/main.go", intent: .normal)
        XCTAssertEqual(shown.texts, [LinkPolicy.TextLink(url: url, line: nil, session: session.id, sizePercent: 75)])
        XCTAssertTrue(shown.revealed.isEmpty)

        let refused = recordLinks(mode: .overlay, overlayOpens: false)
        pane.openLink("file:///tmp/main.go", intent: .normal)
        XCTAssertEqual(refused.texts.count, 1)
        XCTAssertEqual(refused.revealed, [url])
    }

    func testARelativeLocationIsResolvedOffTheMainActorAgainstThePaneDirectory() async throws {
        let session = Session(initialCwd: "/w")
        let pane = bareSurface()
        pane.session = session
        let followed = recordLinks(mode: .overlay, overlayOpens: true)
        let probe = ExistsProbe(["/w/src/a.go"])
        LinkOpener.shared.exists = { probe.check($0) }

        pane.openLink("src/a.go:42:7", intent: .normal)

        try await waitUntil { !followed.texts.isEmpty }
        XCTAssertEqual(followed.texts, [LinkPolicy.TextLink(url: URL(fileURLWithPath: "/w/src/a.go", isDirectory: false), line: 42,
                                                            session: session.id, sizePercent: nil)])
        XCTAssertEqual(probe.paths, ["/w/src/a.go:42:7", "/w/src/a.go"])
        XCTAssertEqual(probe.onMain, [false, false])
    }

    func testALiteralColonNameWinsAndAMissingLocationKeepsItsTypedRoute() async throws {
        let session = Session(initialCwd: "/w")
        let pane = bareSurface()
        pane.session = session
        let literal = recordLinks(mode: .overlay, overlayOpens: true)
        LinkOpener.shared.exists = { $0 == "/x/a.go:42" || $0 == "/x/a.go" }
        pane.openLink("/x/a.go:42", intent: .normal)
        try await waitUntil { !literal.revealed.isEmpty }
        XCTAssertEqual(literal.revealed, [URL(fileURLWithPath: "/x/a.go:42", isDirectory: false)])
        XCTAssertTrue(literal.texts.isEmpty)

        let missing = recordLinks(mode: .overlay, overlayOpens: true)
        pane.openLink("/x/b.go:3", intent: .normal)
        pane.openLink("./c.go:3", intent: .normal)
        try await waitUntil { !missing.revealed.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(missing.revealed, [URL(fileURLWithPath: "/x/b.go:3", isDirectory: false)])
        XCTAssertTrue(missing.texts.isEmpty)
        XCTAssertTrue(missing.opened.isEmpty)
    }

    func testAMarkdownPathEndingASentenceOpensTheFileWithoutThePeriod() async throws {
        let session = Session(initialCwd: "/w")
        let pane = bareSurface()
        pane.session = session
        let followed = recordLinks(mode: .overlay, overlayOpens: true)
        let probe = ExistsProbe(["/tmp/review.md"])
        LinkOpener.shared.exists = { probe.check($0) }

        pane.openLink("/tmp/review.md.", intent: .normal)

        try await waitUntil { !followed.markdowns.isEmpty }
        XCTAssertEqual(followed.markdowns.map(\.0), [URL(fileURLWithPath: "/tmp/review.md", isDirectory: false)])
        XCTAssertEqual(probe.paths, ["/tmp/review.md.", "/tmp/review.md"])
        XCTAssertTrue(followed.revealed.isEmpty)

        let missing = recordLinks(mode: .overlay, overlayOpens: true)
        pane.openLink("/tmp/gone.md.", intent: .normal)
        try await waitUntil { !missing.revealed.isEmpty }
        XCTAssertEqual(missing.revealed, [URL(fileURLWithPath: "/tmp/gone.md.", isDirectory: false)])
        XCTAssertTrue(missing.markdowns.isEmpty)
    }

    func testShellMetacharactersInTheDirectoryAndPathStayFilesystemData() async throws {
        let session = Session(initialCwd: "/w;$(touch /tmp/agterm-pwned)`id`'q\"")
        let pane = bareSurface()
        pane.session = session
        let followed = recordLinks(mode: .overlay, overlayOpens: true)
        let probe = ExistsProbe([])
        LinkOpener.shared.exists = { probe.check($0) }

        pane.openLink("./a;$(rm -rf x)`id`'.go:3", intent: .normal)

        try await waitUntil { probe.paths.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(probe.paths, ["/w;$(touch /tmp/agterm-pwned)`id`'q\"/a;$(rm -rf x)`id`'.go:3",
                                     "/w;$(touch /tmp/agterm-pwned)`id`'q\"/a;$(rm -rf x)`id`'.go"])
        XCTAssertTrue(followed.opened.isEmpty)
        XCTAssertTrue(followed.revealed.isEmpty)
        XCTAssertTrue(followed.texts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/agterm-pwned"))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not reached") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testARevealIntentSelectsEveryLocalFileInFinderAndOpensNone() async throws {
        let session = Session(initialCwd: "/w")
        let pane = bareSurface()
        pane.session = session
        let followed = recordLinks(mode: .overlay, overlayOpens: true)
        LinkOpener.shared.exists = { $0 == "/x/a.go" }
        let files = ["/tmp/a.go", "/tmp/a.png", "/tmp/r.md", "/tmp/Run.command", "/Applications/Some.app", "/tmp/a.html",
                     "/tmp/a.svg", "file:///tmp/b.go"]

        for raw in files { pane.openLink(raw, intent: .reveal) }
        pane.openLink("/x/a.go:3", intent: .reveal)
        try await waitUntil { followed.revealed.count == files.count + 1 }

        let paths = files.map { $0.replacingOccurrences(of: "file://", with: "") } + ["/x/a.go"]
        XCTAssertEqual(followed.revealed, paths.map { URL(fileURLWithPath: $0, isDirectory: false) })
        XCTAssertTrue(followed.opened.isEmpty)
        XCTAssertTrue(followed.texts.isEmpty && followed.images.isEmpty && followed.markdowns.isEmpty && followed.overlaid.isEmpty)
    }

    func testARevealIntentLeavesAWebLinkToItsRouteAndARefusedPathIgnored() throws {
        let session = Session(initialCwd: "/w")
        let pane = bareSurface()
        pane.session = session
        let web = try XCTUnwrap(URL(string: "https://example.com/pr/1"))
        let followed = recordLinks(mode: .overlay, overlayOpens: true)

        pane.openLink(web.absoluteString, intent: .reveal)
        pane.openLink("/net/host/a.go", intent: .reveal)
        pane.openLink("file://otherhost/tmp/a.go", intent: .reveal)
        pane.openLink("//host/share/a.go", intent: .reveal)

        XCTAssertEqual(followed.overlaid.map(\.0), [web])
        XCTAssertTrue(followed.revealed.isEmpty)
        XCTAssertTrue(followed.opened.isEmpty)
    }

    func testARemotePaneIgnoresABarePath() {
        let session = Session(initialCwd: NSTemporaryDirectory(), remoteHost: "buildbox")
        let pane = bareSurface()
        pane.session = session

        let followed = recordLinks(mode: .overlay, overlayOpens: true)
        pane.openLink("/tmp/shot.png", intent: .normal)
        pane.openLink("/tmp/notes.md", intent: .normal)
        XCTAssertTrue(followed.images.isEmpty)
        XCTAssertTrue(followed.markdowns.isEmpty)
        XCTAssertTrue(followed.revealed.isEmpty)
    }

    func testAPaneLinkGoesToTheOverlayInOverlayModeAndToTheBrowserWhenItCannotOpen() throws {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        let url = try XCTUnwrap(URL(string: "https://example.com/pr/1"))

        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        pane.openLink(url.absoluteString, intent: .normal)
        XCTAssertEqual(shown.overlaid.map(\.0), [url])
        XCTAssertEqual(shown.overlaid.map(\.1), [session.id])
        XCTAssertEqual(shown.overlaid.map(\.2), [nil])
        XCTAssertTrue(shown.opened.isEmpty)

        let sized = recordLinks(mode: .overlay75, overlayOpens: true)
        pane.openLink(url.absoluteString, intent: .normal)
        XCTAssertEqual(sized.overlaid.map(\.2), [75])

        let refused = recordLinks(mode: .overlay, overlayOpens: false)
        pane.openLink(url.absoluteString, intent: .normal)
        XCTAssertEqual(refused.overlaid.count, 1)
        XCTAssertEqual(refused.opened, [url])
    }

    func testBrowserModeAHudAndNonWebLinksNeverReachTheOverlay() throws {
        let session = Session(initialCwd: NSTemporaryDirectory())
        let pane = bareSurface()
        pane.session = session
        let hud = bareSurface()
        hud.focusSession = session
        hud.hudBodyFile = "/tmp/agterm-test-hud-body-missing"
        defer { hud.hudBodyFile = nil }
        let web = try XCTUnwrap(URL(string: "https://example.com/"))
        let mail = try XCTUnwrap(URL(string: "mailto:a@example.com"))

        let browser = recordLinks(mode: .browser, overlayOpens: true)
        pane.openLink(web.absoluteString, intent: .normal)
        XCTAssertEqual(browser.opened, [web])

        let overlay = recordLinks(mode: .overlay, overlayOpens: true)
        hud.openLink(web.absoluteString, intent: .normal)
        pane.openLink(mail.absoluteString, intent: .normal)
        pane.openLink("file:///tmp/x.bin", intent: .normal)
        pane.openLink("x-custom://run", intent: .normal)
        XCTAssertEqual(overlay.opened, [web, mail])
        XCTAssertEqual(overlay.revealed, [URL(fileURLWithPath: "/tmp/x.bin", isDirectory: false)])
        XCTAssertTrue(browser.overlaid.isEmpty && overlay.overlaid.isEmpty)
    }

    func testCommandShiftClickOnADetectedURLOpensTheBrowserInOverlayMode() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1")
        defer { fixture.close() }
        let url = try XCTUnwrap(URL(string: "https://example.com/pr/1"))

        let plain = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: .command)
        fixture.click(flags: .command)
        fixture.wait { !plain.overlaid.isEmpty }
        XCTAssertEqual(plain.overlaid.map(\.0), [url], fixture.geometry)
        XCTAssertTrue(plain.opened.isEmpty)

        let chord = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: [.command, .shift])
        fixture.click(flags: [.command, .shift])
        fixture.wait { !chord.opened.isEmpty }
        XCTAssertEqual(chord.opened, [url], fixture.geometry)
        XCTAssertTrue(chord.overlaid.isEmpty)
    }

    func testCommandShiftClickOnAnOSC8LinkOpensItsTargetInTheBrowser() throws {
        let fixture = try LinkClickFixture(printing: #"\033]8;;https://example.com/osc\033\\open the pull request\033]8;;\033\\"#)
        defer { fixture.close() }
        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: [.command, .shift])
        fixture.click(flags: [.command, .shift])
        fixture.wait { !shown.opened.isEmpty }
        XCTAssertEqual(shown.opened, [try XCTUnwrap(URL(string: "https://example.com/osc"))], fixture.geometry)
        XCTAssertTrue(shown.overlaid.isEmpty)
    }

    func testShiftPressedUnderAStillPointerKeepsTheLinkHovered() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1")
        defer { fixture.close() }
        _ = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: .command)
        fixture.wait { fixture.surface.mouseShape == GHOSTTY_MOUSE_SHAPE_POINTER }
        fixture.flagsChanged(keyCode: 56, flags: [.shift, .command])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(fixture.surface.mouseShape, GHOSTTY_MOUSE_SHAPE_POINTER, fixture.geometry)
    }

    func testCommandShiftClickOnAStillPointerWithoutAModifierChangeOpensTheBrowser() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1")
        defer { fixture.close() }
        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: [])
        fixture.click(flags: [.command, .shift])
        fixture.wait { !shown.opened.isEmpty }
        XCTAssertEqual(shown.opened, [try XCTUnwrap(URL(string: "https://example.com/pr/1"))], fixture.geometry)
    }

    func testCommandShiftClickUnderMouseCaptureFollowsTheOverlaySetting() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1", before: #"\033[?1000h"#)
        defer { fixture.close() }
        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.wait { fixture.surface.surface.map(ghostty_surface_mouse_captured) == true }
        fixture.move(flags: [.command, .shift])
        fixture.click(flags: [.command, .shift])
        fixture.wait { !shown.opened.isEmpty || !shown.overlaid.isEmpty }
        XCTAssertEqual(shown.overlaid.map(\.0), [try XCTUnwrap(URL(string: "https://example.com/pr/1"))], fixture.geometry)
        XCTAssertTrue(shown.opened.isEmpty)
    }

    func testCommandOptionClickOnAPrintedPathRevealsItWhereCommandClickShowsIt() throws {
        let fixture = try LinkClickFixture(printing: "/tmp/agterm-reveal-chord.go")
        defer { fixture.close() }
        let url = URL(fileURLWithPath: "/tmp/agterm-reveal-chord.go", isDirectory: false)

        let plain = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: .command)
        fixture.click(flags: .command)
        fixture.wait { !plain.texts.isEmpty }
        XCTAssertEqual(plain.texts.map(\.url), [url], fixture.geometry)

        let chord = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: [.command, .option])
        fixture.click(flags: [.command, .option])
        fixture.wait { !chord.revealed.isEmpty }
        XCTAssertEqual(chord.revealed, [url], fixture.geometry)
        XCTAssertTrue(chord.texts.isEmpty && chord.opened.isEmpty)
    }

    func testCommandOptionShiftClickUnderMouseCaptureRevealsThePath() throws {
        let fixture = try LinkClickFixture(printing: "/tmp/agterm-reveal-chord.go", before: #"\033[?1000h"#)
        defer { fixture.close() }
        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.wait { fixture.surface.surface.map(ghostty_surface_mouse_captured) == true }
        fixture.move(flags: [.command, .option, .shift])
        fixture.click(flags: [.command, .option, .shift])
        fixture.wait { !shown.revealed.isEmpty }
        XCTAssertEqual(shown.revealed, [URL(fileURLWithPath: "/tmp/agterm-reveal-chord.go", isDirectory: false)], fixture.geometry)
        let forwarded = fixture.forwardedMods(flags: [.command, .option, .shift]).rawValue
        XCTAssertNotEqual(forwarded & GHOSTTY_MODS_SHIFT.rawValue, 0, "shift stays, the bypass libghostty decides on")
        XCTAssertEqual(forwarded & (GHOSTTY_MODS_ALT.rawValue | GHOSTTY_MODS_ALT_RIGHT.rawValue), 0)
    }

    func testOptionClickAloneIsNotALinkClick() throws {
        let fixture = try LinkClickFixture(printing: "/tmp/agterm-reveal-chord.go")
        defer { fixture.close() }
        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.move(flags: .option)
        fixture.click(flags: .option)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertTrue(shown.revealed.isEmpty && shown.texts.isEmpty && shown.opened.isEmpty)
    }

    func testACommandOptionDragStartingOnOrCrossingALinkKeepsItsRectangleAndRevealsNothing() throws {
        let fixture = try LinkClickFixture(printing: #"/tmp/agterm-drag-target.go\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"#)
        defer { fixture.close() }
        let followed = recordLinks(mode: .overlay, overlayOpens: true)

        fixture.drag(from: try fixture.cell(column: 1, rowsAboveCursor: 1), to: try fixture.cell(column: 5, rowsAboveCursor: 0),
                     flags: [.command, .option])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let fromLink = try XCTUnwrap(fixture.surface.readSelection(), fixture.geometry)
        XCTAssertTrue(fromLink.contains("\n"), "both rows are selected: \(fromLink)")
        XCTAssertFalse(fromLink.contains("agterm-drag-target"), "a rectangle stops at the drag's column: \(fromLink)")

        fixture.drag(from: try fixture.cell(column: 0, rowsAboveCursor: 0), to: try fixture.cell(column: 25, rowsAboveCursor: 1),
                     flags: [.command, .option])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let acrossLink = try XCTUnwrap(fixture.surface.readSelection(), fixture.geometry)
        XCTAssertTrue(acrossLink.contains("agterm-drag-target"), "a rectangle keeps the upper row's columns: \(acrossLink)")
        XCTAssertFalse(acrossLink.contains("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), "and the lower row's: \(acrossLink)")
        XCTAssertTrue(followed.revealed.isEmpty && followed.texts.isEmpty && followed.opened.isEmpty)
    }

    // regression: a drag ending within a few points of its press still crossed a row and lost its rectangle
    func testAShortCommandOptionDragAcrossARowStaysARectangle() throws {
        let fixture = try LinkClickFixture(printing: #"/tmp/agterm-drag-target.go\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"#)
        defer { fixture.close() }
        let followed = recordLinks(mode: .overlay, overlayOpens: true)
        // 0.3 cells right across the 60% column threshold and 1 point down across the row edge: under 3 points
        let start = try fixture.cell(column: 5, rowsAboveCursor: 1, across: 0.4, up: 0.5 / 17)
        let end = try fixture.cell(column: 5, rowsAboveCursor: 0, across: 0.7, up: 1 - 0.5 / 17)
        XCTAssertLessThan(hypot(end.x - start.x, end.y - start.y), 3)

        fixture.drag(from: start, to: end, flags: [.command, .option])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let selection = try XCTUnwrap(fixture.surface.readSelection(), fixture.geometry)
        XCTAssertTrue(selection.contains("\n"), "both rows are selected: \(selection)")
        XCTAssertFalse(selection.contains("agterm-drag-target"), "a one-column rectangle: \(selection)")
        XCTAssertTrue(followed.revealed.isEmpty && followed.texts.isEmpty)
    }

    func testAHudPanelForwardsTheRevealChordAsALinkClick() throws {
        let fixture = try LinkClickFixture(printing: "/tmp/agterm-reveal-chord.go")
        defer { fixture.close() }
        fixture.surface.hudBodyFile = "/tmp/agterm-test-hud-body-missing"
        defer { fixture.surface.hudBodyFile = nil }
        let shown = recordLinks(mode: .overlay, overlayOpens: true)
        fixture.passiveClick(flags: [.command, .option])
        fixture.wait { !shown.revealed.isEmpty }
        XCTAssertEqual(shown.revealed, [URL(fileURLWithPath: "/tmp/agterm-reveal-chord.go", isDirectory: false)], fixture.geometry)
    }

    func testCommandShiftClickInBrowserModeIsNotALinkClick() throws {
        let fixture = try LinkClickFixture(printing: "https://example.com/pr/1")
        defer { fixture.close() }
        let shown = recordLinks(mode: .browser, overlayOpens: true)
        fixture.move(flags: [.command, .shift])
        fixture.click(flags: [.command, .shift])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertTrue(shown.opened.isEmpty && shown.overlaid.isEmpty)
    }

    func testAnsweringFocusedAskReturnsKeysToItsTerminal() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let terminal = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        defer { terminal.teardown() }
        terminal.focusSession = fixture.session
        fixture.session.splitSurface = terminal
        fixture.session.splitFocused = true
        try fixture.open(pane: .right)
        fixture.mount()
        terminal.frame = CGRect(x: 300, y: 0, width: 300, height: 300)
        fixture.window.contentView?.addSubview(terminal, positioned: .below, relativeTo: nil)
        terminal.createSurface()
        let catcher = try XCTUnwrap(fixture.catcher)
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        fixture.window.makeFirstResponder(catcher)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: fixture.window.windowNumber, context: nil,
                                                 characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        catcher.keyDown(with: event)
        let deadline = Date(timeIntervalSinceNow: 1)
        while fixture.window.firstResponder !== terminal, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result.result, .answered)
        XCTAssertTrue(fixture.window.firstResponder === terminal)
    }

    func testUncoveredProgramOverlayClickLeavesTheAskPaneAndKeepsTypingAvailable() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(pane: .right)
        fixture.session.splitFocused = true
        fixture.mount()
        let terminal = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        defer { terminal.teardown() }
        terminal.focusSession = fixture.session
        fixture.session.overlayActive = true
        fixture.session.overlaySurface = terminal
        terminal.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        fixture.window.contentView?.addSubview(terminal, positioned: .below, relativeTo: nil)
        terminal.createSurface()
        XCTAssertNotNil(terminal.surface)
        fixture.catcher?.grabFocus()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 100),
                                                   modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        terminal.mouseDown(with: event)
        XCTAssertFalse(fixture.session.splitFocused)
        XCTAssertTrue(fixture.window.firstResponder === terminal)
        XCTAssertFalse(terminal.askBlocksFocus)
        XCTAssertNotNil(fixture.session.askPending)
    }

    func testMouseAndReparentFocusDoNotStealFromTheCoveredPaneAsk() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(pane: .right)
        fixture.session.splitFocused = true
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        let terminal = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        defer { terminal.teardown() }
        terminal.focusSession = fixture.session
        fixture.session.splitSurface = terminal
        terminal.frame = CGRect(x: 300, y: 0, width: 300, height: 300)
        fixture.window.contentView?.addSubview(terminal, positioned: .below, relativeTo: nil)
        terminal.createSurface()
        XCTAssertNotNil(terminal.surface)
        fixture.window.makeFirstResponder(catcher)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 350, y: 100),
                                                   modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        terminal.mouseDown(with: event)
        terminal.focusAfterReparent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
        XCTAssertTrue(fixture.window.firstResponder === catcher)
        XCTAssertTrue(terminal.askBlocksFocus)
        fixture.session.splitFocused = false
        XCTAssertFalse(terminal.askBlocksFocus)
    }

    private var surface: GhosttySurfaceView!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            savedOpener = LinkOpener.shared
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            surface = nil
            LinkOpener.shared = savedOpener
        }
        try await super.tearDown()
    }

    func testSelectedRangeIsAnEmptyInsertionPointWithoutAComposition() {
        XCTAssertFalse(surface.hasMarkedText())
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testSelectedRangeIsTheImeSelectionWhileComposing() {
        surface._markedRange = NSRange(location: 0, length: 5)
        surface._selectedRange = NSRange(location: 5, length: 0)
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testSelectedRangeDropsTheStaleImeSelectionOnceCompositionEnds() {
        surface._markedRange = NSRange(location: 0, length: 5)
        surface._selectedRange = NSRange(location: 5, length: 0)
        surface._markedRange = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(surface.selectedRange(), NSRange(location: 0, length: 0))
    }
}

@MainActor
private final class LinkClickFixture {
    let surface: GhosttySurfaceView
    private let window: NSWindow
    private let session = Session(initialCwd: NSTemporaryDirectory())
    private var link = NSPoint.zero
    private let blank = NSPoint(x: 40, y: 20)

    init(printing text: String, before prefix: String = "") throws {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "printf '\(prefix)\(text)'; cat")
        surface.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(surface)
        surface.createSurface()
        XCTAssertTrue(surface.isRealized)
        let printed = { self.surface.readScreenText(all: false, lines: nil).map { ["example", "pull request", "/tmp/"].contains(where: $0.contains) } == true }
        wait(printed)
        XCTAssertTrue(printed())
        let raw = try XCTUnwrap(surface.surface)
        let cell = try XCTUnwrap(surface.cellSize())
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(raw, &x, &y, &w, &h)
        link = NSPoint(x: x - 6 * cell.width, y: surface.bounds.height - (y - cell.height / 2))
        XCTAssertTrue(surface.bounds.contains(link))
        surface.session = session
    }

    var geometry: String {
        "link=\(link) cell=\(String(describing: surface.cellSize())) shape=\(surface.mouseShape.rawValue) "
            + "screen=<<\(surface.readScreenText(all: false, lines: nil) ?? "nil")>>"
    }

    func close() {
        surface.teardown()
        window.close()
    }

    func move(flags: NSEvent.ModifierFlags) {
        for point in [blank, link] { surface.mouseMoved(with: mouseEvent(.mouseMoved, at: point, flags: flags)) }
    }

    func click(flags: NSEvent.ModifierFlags) {
        surface.mouseDown(with: mouseEvent(.leftMouseDown, at: link, flags: flags))
        surface.mouseUp(with: mouseEvent(.leftMouseUp, at: link, flags: flags))
    }

    /// cell is a window point inside a cell, `across` and `up` its fractions from the cell's left and bottom
    /// edges. The IME point is the cursor cell's horizontal midpoint at its bottom edge, as `readCursorColumn`
    /// solves it.
    func cell(column: Int, rowsAboveCursor rows: Int, across: Double = 0.5, up: Double = 0.5) throws -> NSPoint {
        let raw = try XCTUnwrap(surface.surface)
        let cell = try XCTUnwrap(surface.cellSize())
        let cursor = try XCTUnwrap(surface.readCursorColumn())
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(raw, &x, &y, &w, &h)
        let column0 = x - (Double(cursor) + 0.5) * cell.width
        let rowBottom = y - Double(rows) * cell.height
        return NSPoint(x: column0 + (Double(column) + across) * cell.width, y: surface.bounds.height - rowBottom + up * cell.height)
    }

    func drag(from start: NSPoint, to end: NSPoint, flags: NSEvent.ModifierFlags) {
        surface.mouseMoved(with: mouseEvent(.mouseMoved, at: start, flags: flags))
        surface.mouseDown(with: mouseEvent(.leftMouseDown, at: start, flags: flags))
        // the release lands past the last drag event, as a real one can, so libghostty redraws from its mods
        for step in 1..<8 {
            let t = Double(step) / 8
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            surface.mouseDragged(with: mouseEvent(.leftMouseDragged, at: point, flags: flags))
        }
        surface.mouseUp(with: mouseEvent(.leftMouseUp, at: end, flags: flags))
    }

    func forwardedMods(flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        surface.linkMods(mouseEvent(.leftMouseDown, at: link, flags: flags))
    }

    func passiveClick(flags: NSEvent.ModifierFlags) {
        let point = surface.convert(link, to: nil)
        surface.passivePointer(at: point, with: mouseEvent(.mouseMoved, at: link, flags: flags))
        surface.passiveClick(GHOSTTY_MOUSE_PRESS, with: mouseEvent(.leftMouseDown, at: link, flags: flags))
        surface.passiveClick(GHOSTTY_MOUSE_RELEASE, with: mouseEvent(.leftMouseUp, at: link, flags: flags))
    }

    func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(with: .flagsChanged, location: link, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "",
                                     charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
        surface.flagsChanged(with: event!)
    }

    func wait(_ done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
