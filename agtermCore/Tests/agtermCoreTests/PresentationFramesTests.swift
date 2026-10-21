import Foundation
import Testing
@testable import agtermCore

struct PresentationFramesTests {
    static let pane = PresentationPane.identity(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    static let status = PresentationStatus(status: .blocked, blink: true, color: "#ff8800", shape: .diamond,
                                           pane: pane, changedAt: 1_789_000_000)
    static let hud = PresentationHud(spec: HudSpec(message: "deploying", hideAfter: 10), pane: nil,
                                     generation: 4, remaining: 7.5)
    static let paneHud = PresentationHud(spec: HudSpec(message: "deploying"), pane: pane, generation: 5,
                                         remaining: nil)

    static let frames: [PresentationFrame] = [
        PresentationFrame(gen: 1, rev: 0, body: .hello(PresentationHello(
            version: 1, kinds: ["status", "hud", "notify"], mode: .mirror))),
        PresentationFrame(gen: 1, rev: 1, body: .ping),
        PresentationFrame(gen: 1, rev: 2, body: .ack),
        PresentationFrame(gen: 1, rev: 3, body: .snapshot(PresentationSnapshot(status: status, hud: hud))),
        PresentationFrame(gen: 1, rev: 4, body: .snapshot(PresentationSnapshot(status: nil, hud: nil))),
        PresentationFrame(gen: 1, rev: 5, body: .status(status)),
        PresentationFrame(gen: 1, rev: 6, body: .status(nil)),
        PresentationFrame(gen: 1, rev: 7, body: .status(PresentationStatus(
            status: .active, blink: false, color: nil, shape: nil, pane: .scratch, changedAt: nil))),
        PresentationFrame(gen: 1, rev: 8, body: .hud(hud)),
        PresentationFrame(gen: 1, rev: 9, body: .hud(nil)),
        PresentationFrame(gen: 1, rev: 11, body: .hud(paneHud)),
        PresentationFrame(gen: 1, rev: 12, body: .snapshot(PresentationSnapshot(status: nil, hud: paneHud))),
        PresentationFrame(gen: 2, rev: 10, body: .notify(PresentationNotify(
            title: "build", body: "done", pane: pane, source: "control"))),
        PresentationFrame(gen: 1, rev: 13, body: .hello(PresentationHello(
            version: 1, kinds: ["status"], mode: .presenter))),
        PresentationFrame(gen: 1, rev: 14, body: .presenterAcquire),
        PresentationFrame(gen: 1, rev: 15, body: .presenterGranted),
        PresentationFrame(gen: 1, rev: 16, body: .presenterRefused),
        PresentationFrame(gen: 1, rev: 17, body: .askRequest(PresentationAsk(
            PendingAsk(id: "a1", title: "deploy?", message: "to prod", buttons: [ControlAskButton(id: "y", label: "Yes", hotkey: "y")],
                       defaultID: "y", style: .gui, align: .center, width: 40),
            pane: pane, owner: 3))),
        PresentationFrame(gen: 1, rev: 18, body: .askResolve(PresentationAskAnswer(id: "a1", owner: 3, button: "y"))),
        PresentationFrame(gen: 1, rev: 19, body: .askResolve(PresentationAskAnswer(id: "a1", owner: 3, button: nil))),
        PresentationFrame(gen: 1, rev: 20, body: .askRejected(PresentationAskRef(id: "a1", owner: 3))),
        PresentationFrame(gen: 1, rev: 21, body: .askDismiss(PresentationAskRef(id: "a1", owner: 3))),
        PresentationFrame(gen: 1, rev: 22, body: .overlayRequest(PresentationOverlay(
            job: "j1", pane: pane, sizePercent: 60, backgroundColor: "#102030", follow: true, wait: true))),
        PresentationFrame(gen: 1, rev: 23, body: .overlayRequest(PresentationOverlay(
            job: "j1", pane: nil, sizePercent: nil, backgroundColor: nil, follow: false, wait: false))),
        PresentationFrame(gen: 1, rev: 24, body: .overlayRejected(PresentationOverlayChange(job: "j1"))),
        PresentationFrame(gen: 1, rev: 25, body: .overlayClose(PresentationOverlayChange(job: "j1"))),
        PresentationFrame(gen: 1, rev: 26, body: .overlayResize(PresentationOverlayChange(job: "j1", sizePercent: 40))),
        PresentationFrame(gen: 1, rev: 27, body: .overlayClosed(PresentationOverlayChange(job: "j1"))),
        PresentationFrame(gen: 1, rev: 28, body: .context("PR #517")),
        PresentationFrame(gen: 1, rev: 29, body: .context(nil)),
        PresentationFrame(gen: 1, rev: 30, body: .snapshot(PresentationSnapshot(status: nil, hud: nil, context: "PR #517"))),
        PresentationFrame(gen: 1, rev: 31, body: .sound(PresentationSound(name: "Glass"))),
        PresentationFrame(gen: 1, rev: 32, body: .sound(PresentationSound(name: nil))),
        PresentationFrame(gen: 1, rev: 33, body: .askRequest(PresentationAsk(
            PendingAsk(id: "a2", title: "pick", buttons: [ControlAskButton(id: "ok", label: "OK")],
                       form: .choices(AskChoiceForm(choices: [ControlAskChoice(id: "a", label: "A")], multiple: true, other: "Other"))),
            pane: nil, owner: 3))),
        PresentationFrame(gen: 1, rev: 34, body: .askResolve(PresentationAskAnswer(id: "a2", owner: 3, button: "ok", text: " mine ",
                                                                                   selected: ["a"]))),
        PresentationFrame(gen: 1, rev: 35, body: .pageRequest(PresentationPage(
            page: "p1", token: "t1", source: .url("https://example.com/review/42?token=abc&x=1#top"), identity: "https://example.com",
            chromeless: false, javascript: true, navigation: true, browse: false, persistent: true, backgroundColor: nil,
            pane: nil, sizePercent: 80, follow: true))),
        PresentationFrame(gen: 1, rev: 36, body: .pageRequest(PresentationPage(
            page: "p2", token: "t2", source: .file(path: "/Users/u/docs/index.html", grantRoot: "/Users/u/docs"), identity: "index.html",
            chromeless: true, javascript: true, navigation: false, browse: false, persistent: false, backgroundColor: "#102030",
            pane: pane, sizePercent: nil, follow: false))),
        PresentationFrame(gen: 1, rev: 37, body: .pageRequest(PresentationPage(
            page: "p3", token: "t3", source: .file(path: "/tmp/r.html", grantRoot: nil), identity: "r.html",
            chromeless: false, javascript: false, navigation: false, browse: false, persistent: false, backgroundColor: nil,
            pane: nil, sizePercent: nil, follow: false))),
        PresentationFrame(gen: 1, rev: 38, body: .pageRejected(PresentationPageChange(page: "p1", reason: "slot taken"))),
        PresentationFrame(gen: 1, rev: 39, body: .pageClose(PresentationPageChange(page: "p1"))),
        PresentationFrame(gen: 1, rev: 40, body: .pageClosed(PresentationPageChange(page: "p1"))),
        PresentationFrame(gen: 1, rev: 41, body: .pageCommand(PresentationPageCommand(page: "p1", seq: 7, action: .resize, sizePercent: 50))),
        PresentationFrame(gen: 1, rev: 42, body: .pageCommand(PresentationPageCommand(page: "p1", seq: 8, action: .reloadCurrent))),
        PresentationFrame(gen: 1, rev: 43, body: .pageState(PresentationPageState(
            page: "p1", title: "Review", address: "/Users/u/docs/b.html", load: .loaded, error: nil, canGoBack: true,
            canGoForward: false, hidden: true, appliedSeq: 8))),
    ]

    @Test func aChoiceRequestFromAnOriginWithoutTheOtherRowDecodesWithNone() throws {
        let choices = try JSONDecoder().decode(AskChoiceForm.self, from: Data(#"{"choices":[{"id":"a","label":"A"}],"multiple":false,"checked":[]}"#.utf8))

        #expect(choices == AskChoiceForm(choices: [ControlAskChoice(id: "a", label: "A")]))
        #expect(choices.other == nil)
    }

    @Test(arguments: frames)
    func everyFrameSurvivesARoundTrip(_ frame: PresentationFrame) throws {
        let line = try PresentationCodec.encode(frame)

        #expect(line.last == UInt8(ascii: "\n"))
        #expect(!line.dropLast().contains(UInt8(ascii: "\n")))
        #expect(try PresentationCodec.decode(line.dropLast()) == frame)
    }

    @Test func pageStateBoundsThePagesOwnStrings() throws {
        let long = String(repeating: "x", count: 100_000)
        let state = PresentationPageState(page: "p1", title: long, address: long, load: .failed, error: long, canGoBack: false,
                                          canGoForward: false, hidden: false, appliedSeq: 0)

        #expect(state.title?.count == PresentationPageState.maxTitle)
        #expect(state.address?.count == PresentationPageState.maxAddress)
        #expect(state.error?.count == PresentationPageState.maxError)
        #expect(try PresentationCodec.encode(PresentationFrame(gen: .max, rev: .max, body: .pageState(state))).count
            < PresentationCodec.maxFrameBytes)
    }

    @Test func anUnknownKindDecodesToUnknownAndKeepsItsOrdering() throws {
        let line = Data(#"{"kind":"future.kind","gen":3,"rev":12,"job":"abc"}"#.utf8)

        #expect(try PresentationCodec.decode(line) == PresentationFrame(gen: 3, rev: 12,
                                                                        body: .unknown("future.kind")))
    }

    @Test func aSnapshotFromAnOriginWithoutContextDecodesWithNone() throws {
        let line = Data(#"{"kind":"snapshot","gen":1,"rev":1,"snapshot":{}}"#.utf8)

        #expect(try PresentationCodec.decode(line) == PresentationFrame(
            gen: 1, rev: 1, body: .snapshot(PresentationSnapshot(status: nil, hud: nil, context: nil))))
    }

    @Test func anOversizeLineIsRefusedBeforeDecoding() {
        let line = Data(repeating: UInt8(ascii: "x"), count: PresentationCodec.maxFrameBytes + 1)

        #expect(throws: PresentationCodec.FrameError.oversize(line.count)) {
            try PresentationCodec.decode(line)
        }
    }

    @Test func aMarkdownHudWithItsFontSizeSurvivesAFrame() throws {
        let hud = PresentationHud(spec: HudSpec(message: "# Tasks\n\n- build", markdown: true, fontSize: 18),
                                  pane: nil, generation: 2, remaining: nil)
        let frame = PresentationFrame(gen: 1, rev: 3, body: .hud(hud))

        let line = try PresentationCodec.encode(frame)

        #expect(try PresentationCodec.decode(line.dropLast()) == frame)
    }

    @Test func theLargestMarkdownHudFitsAFrame() throws {
        let message = String(repeating: "\u{1F600}", count: HudSpec.maxMarkdownLength)
        let hud = PresentationHud(spec: HudSpec(message: message, detail: String(repeating: "\u{1F600}", count: HudSpec.maxTextLength),
                                                markdown: true), pane: nil, generation: 1, remaining: nil)

        let line = try PresentationCodec.encode(PresentationFrame(gen: 1, rev: 1, body: .hud(hud)))

        #expect(line.count <= PresentationCodec.maxFrameBytes)
    }

    @Test func aFrameThatWouldEncodeOversizeIsRefused() {
        let body = String(repeating: "x", count: PresentationCodec.maxFrameBytes)
        let frame = PresentationFrame(gen: 1, rev: 1, body: .notify(PresentationNotify(
            title: "t", body: body, pane: nil, source: "control")))

        #expect(throws: PresentationCodec.FrameError.self) { try PresentationCodec.encode(frame) }
    }

    @Test(arguments: ["not json", #"{"gen":1,"rev":1}"#, #"{"kind":"status","rev":1}"#,
                      #"{"kind":"hello","gen":1,"rev":1}"#])
    func aMalformedLineReportsWhatWasWrong(_ text: String) {
        #expect {
            try PresentationCodec.decode(Data(text.utf8))
        } throws: { error in
            guard case PresentationCodec.FrameError.malformed(let detail) = error else { return false }
            return !detail.isEmpty
        }
    }

    @Test(arguments: [(1, 1, 1), (1, 3, 1), (3, 1, 1), (2, 5, 2)])
    func negotiationPicksTheLowerVersion(_ ours: Int, _ theirs: Int, _ expected: Int) {
        #expect(PresentationCodec.negotiatedVersion(ours: ours, theirs: theirs) == expected)
    }

    @Test(arguments: [0, -1])
    func aPeerBelowVersionOneCannotBeNegotiated(_ theirs: Int) {
        #expect(PresentationCodec.negotiatedVersion(ours: 1, theirs: theirs) == nil)
    }
}
