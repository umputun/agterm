import Foundation
import Testing
@testable import agtermCore

struct PresentationLinkTests {
    private static let pane = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private static let click = UUID(uuidString: "0E984725-C51C-4BF4-9960-E1C80E27ABA0")!

    @Test(arguments: [
        PresentationFrame(gen: 1, rev: 1, body: .linkClick(PresentationLinkClick(
            raw: "src/a.md:3", pane: pane, mode: .overlay, click: click, openers: ["*.md", "Makefile"]))),
        PresentationFrame(gen: 1, rev: 4, body: .linkClick(PresentationLinkClick(
            raw: "a.md", pane: pane, mode: .overlay, click: click, openers: ["*.md"], snapshotOnly: true))),
        PresentationFrame(gen: 1, rev: 2, body: .linkRefused(PresentationLinkRefusal(reason: .notFound, click: click))),
        PresentationFrame(gen: 1, rev: 3, body: .linkSnapshot(PresentationLinkSnapshot(
            click: click, token: "tok", name: "a.md", size: 42))),
    ])
    func linkFramesRoundTrip(frame: PresentationFrame) throws {
        #expect(try PresentationCodec.decode(PresentationCodec.encode(frame)) == frame)
    }

    @Test func aClickAndARefusalWithoutAClickIDEncodeNoNewKeys() throws {
        let click = try PresentationCodec.encode(PresentationFrame(gen: 1, rev: 2, body: .linkClick(
            PresentationLinkClick(raw: "/a.md", pane: Self.pane, mode: .overlay))))
        let refusal = try PresentationCodec.encode(PresentationFrame(gen: 1, rev: 3, body: .linkRefused(
            PresentationLinkRefusal(reason: .notFound))))

        for line in [click, refusal] {
            let text = String(decoding: line, as: UTF8.self)
            #expect(!text.contains(#""click""#), "\(text)")
            #expect(!text.contains(#""openers""#), "\(text)")
        }
    }

    @Test func anOlderClickDecodesWithNoClickIDOrRules() throws {
        let line = Data(#"{"kind":"link.click","gen":1,"rev":2,"link":{"raw":"/a.md","pane":"6F9619FF-8B86-D011-B42D-00C04FC964FF","mode":"overlay"}}"#.utf8)

        guard case .linkClick(let click) = try PresentationCodec.decode(line).body else {
            Issue.record("not a link click")
            return
        }
        #expect(click.click == nil)
        #expect(click.openers == nil)
    }

    @Test func malformedNewFieldsDecodeAsAbsentWithoutFailingTheFrame() throws {
        let click = Data(#"{"kind":"link.click","gen":1,"rev":2,"link":{"raw":"/a.md","pane":"6F9619FF-8B86-D011-B42D-00C04FC964FF","mode":"overlay","click":"nope","openers":5}}"#.utf8)
        let refusal = Data(#"{"kind":"link.refused","gen":1,"rev":3,"link":{"reason":"notFound","click":7}}"#.utf8)

        #expect(try PresentationCodec.decode(click).body == .linkClick(
            PresentationLinkClick(raw: "/a.md", pane: Self.pane, mode: .overlay)))
        #expect(try PresentationCodec.decode(refusal).body == .linkRefused(PresentationLinkRefusal(reason: .notFound)))
    }

    @Test @MainActor func aSnapshotTravelsAsItsOwnKind() throws {
        let line = try PresentationCodec.encode(PresentationFrame(gen: 1, rev: 2, body: .linkSnapshot(
            PresentationLinkSnapshot(click: Self.click, token: "tok", name: "a.md", size: 42))))

        #expect(String(decoding: line, as: UTF8.self).contains(#""kind":"link.snapshot""#))
        #expect(PresentationHub.supportedKinds.contains(PresentationHub.linkSnapshotKind))
    }

    @Test func aClicksSelectorsDropMalformedOnesAndNeedAClickID() {
        let long = String(repeating: "a", count: 256) + ".md"
        let click = PresentationLinkClick(raw: "a.md", pane: Self.pane, mode: .overlay, click: Self.click,
                                          openers: ["*.md", "a/b", "*.[md]", long, "Makefile"])

        #expect(click.selectors.map(\.text) == ["*.md", "Makefile"])
        #expect(PresentationLinkClick(raw: "a.md", pane: Self.pane, mode: .overlay, openers: ["*.md"]).selectors.isEmpty)
        let many = PresentationLinkClick(raw: "a.md", pane: Self.pane, mode: .overlay, click: Self.click,
                                         openers: (0..<40).map { "f\($0).md" })
        #expect(many.selectors.count == PresentationLinkClick.maxSelectors)
    }

    @Test(arguments: [
        ("notes.md", 10, true), ("notes.md", MarkdownPage.maxBytes, true), ("notes.md", MarkdownPage.maxBytes + 1, false),
        ("shot.png", ImagePage.maxBytes, true), ("a.zip", 1, false), ("..", 1, false), ("a/b.md", 1, false),
        ("", 1, false), ("notes.md", -1, false),
    ])
    func anOfferIsAcceptableOnlyForAPlainNameWithinItsPagesCap(name: String, size: Int, acceptable: Bool) {
        #expect(PresentationLinkSnapshot(click: Self.click, token: "t", name: name, size: size).isAcceptable == acceptable)
    }

    @Test func snapshotFailedIsWordedForTheViewer() {
        #expect(RemoteLinkRefusal.snapshotFailed.message(host: "buildbox") == "the file from buildbox could not be copied here")
    }
}
