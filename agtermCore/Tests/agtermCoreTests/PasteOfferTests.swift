import Foundation
import Testing
@testable import agtermCore

struct PasteOfferTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47])
    private static let file = URL(fileURLWithPath: "/tmp/my report.png")
    private static let web = URL(string: "https://example.com/a?b=c")!

    @Test(arguments: [
        (PasteOffer(urls: [file], text: "/tmp/my report.png", image: png), PasteOffer.Action.urls([file])),
        (PasteOffer(urls: [web], text: "x"), .urls([web])),
        (PasteOffer(text: "echo hi", image: png), .text("echo hi")),
        (PasteOffer(text: "", image: png), .image(png)),
        (PasteOffer(image: png), .image(png)),
    ])
    func urlsWinOverTextAndTextOverAnImage(offer: PasteOffer, expected: PasteOffer.Action) {
        #expect(offer.action == expected)
    }

    @Test func anOfferWithNothingUsableHasNoAction() {
        #expect(PasteOffer(text: "", image: Data()).action == nil)
        #expect(PasteOffer().action == nil)
    }

    @Test func urlTextEscapesAFilePathAndAWebAddress() {
        #expect(PasteOffer.urlText(Self.file) == "/tmp/my\\ report.png")
        #expect(PasteOffer.urlText(Self.web) == "https://example.com/a\\?b=c")
    }

    @Test func insertTextReplacesEachFileInOrderAndKeepsWebAddresses() {
        let second = URL(fileURLWithPath: "/Users/me/b.txt")
        let offer = PasteOffer(urls: [Self.file, Self.web, second])
        #expect(offer.fileURLs == [Self.file, second])
        #expect(offer.insertText(filePaths: ["/home/u/.cache/p/0/my report.png", "/home/u/.cache/p/1/b.txt"]) ==
            "/home/u/.cache/p/0/my\\ report.png https://example.com/a\\?b=c /home/u/.cache/p/1/b.txt")
    }

    @Test(arguments: [[String](), ["/a"], ["/a", "/b", "/c"]])
    func insertTextRefusesAStagedPathCountThatDoesNotMatchTheFiles(paths: [String]) {
        let offer = PasteOffer(urls: [Self.file, URL(fileURLWithPath: "/Users/me/b.txt")])
        #expect(offer.insertText(filePaths: paths) == nil)
    }

    @Test(arguments: [
        (PasteOffer(urls: [file], image: png), false, PasteOffer.Route.asIs),
        (PasteOffer(urls: [file], image: png), true, .sendToOrigin),
        (PasteOffer(urls: [web, file]), true, .sendToOrigin),
        (PasteOffer(urls: [web], image: png), true, .asIs),
        (PasteOffer(text: "ls", image: png), true, .asIs),
        (PasteOffer(image: png), false, .stageHere),
        (PasteOffer(image: png), true, .sendToOrigin),
        (PasteOffer(), true, .asIs),
    ])
    func onlyFilesAndImagesTheProgramCannotOpenAreCopied(offer: PasteOffer, onOrigin: Bool, expected: PasteOffer.Route) {
        #expect(offer.route(onOrigin: onOrigin) == expected)
    }

    @Test func asIsTextJoinsTheURLsOrKeepsTheText() {
        #expect(PasteOffer(urls: [Self.file, Self.web], text: "ignored").asIsText == "/tmp/my\\ report.png https://example.com/a\\?b=c")
        #expect(PasteOffer(text: "echo $HOME").asIsText == "echo $HOME")
        #expect(PasteOffer(image: Self.png).asIsText == nil)
    }

    @Test func anImageIsNamedForTheMomentItWasPasted() throws {
        var parts = DateComponents(year: 2026, month: 3, day: 7, hour: 9, minute: 5, second: 2)
        parts.timeZone = .current
        let date = try #require(Calendar(identifier: .gregorian).date(from: parts))
        #expect(PasteOffer.imageName(at: date) == "clipboard-20260307-090502.png")
    }
}
