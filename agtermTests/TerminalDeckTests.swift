import AppKit
import SwiftUI
import XCTest
@testable import agterm

@MainActor
final class TerminalDeckTests: XCTestCase {
    func testHiddenHostsAreMeasuredOnlyAtTheDeckSize() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: DeckFixture(recorder: recorder, selected: 0))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize

        XCTAssertEqual(recorder.views.count, 96)
        XCTAssertEqual(Set(recorder.proposals.keys), Set(0..<96))
        XCTAssertTrue(recorder.proposals.values.allSatisfy { proposals in
            !proposals.isEmpty && proposals.allSatisfy { $0.width == 900 && $0.height == 750 }
        }, "terminal hosts must not receive speculative min/ideal/max size proposals")
        XCTAssertEqual(host.fittingSize, CGSize(width: 640, height: 400))
    }

    func testEveryHostStaysMountedAcrossSelectionAndResize() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: DeckFixture(recorder: recorder, selected: 0))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        let originalViews = recorder.views
        XCTAssertEqual(originalViews.count, 96)

        host.rootView = DeckFixture(recorder: recorder, selected: 95)
        host.frame.size = CGSize(width: 1000, height: 650)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(recorder.creations, 96)
        for index in 0..<96 {
            XCTAssertTrue(recorder.views[index] === originalViews[index])
            XCTAssertEqual(recorder.views[index]?.frame.size, CGSize(width: 700, height: 600))
        }
    }

    func testPlaceholderIsCenteredWithNoSessionSelected() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: TerminalDeck {
            DeckProbe(index: 0, recorder: recorder).frame(width: 100, height: 30)
        })
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        let placeholder = recorder.views[0]
        XCTAssertNotNil(placeholder)
        XCTAssertEqual(placeholder?.convert(placeholder?.bounds ?? .zero, to: host),
                       CGRect(x: 250, y: 185, width: 100, height: 30))
    }

    func testPublishesItsTopEdgeToTheDeck() {
        let recorder = DeckTopRecorder()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 50)
            TerminalDeck { DeckTopReader(recorder: recorder) }
        })
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(recorder.deckTop, 50)
    }

    func testAPaneAboveTheDeckTopIsLaidOutBelowIt() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: DeckPaneInset { DeckProbe(index: 0, recorder: recorder) }
            .environment(\.terminalDeckTop, 50))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(topEdge(of: recorder.views[0], in: host), 50)
        XCTAssertEqual(recorder.views[0]?.frame.height, 350)
    }

    func testAPaneAlreadyBelowTheDeckTopKeepsItsFrame() {
        let recorder = DeckRecorder()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 50)
            DeckPaneInset { DeckProbe(index: 0, recorder: recorder) }
        }
        .environment(\.terminalDeckTop, 20))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(topEdge(of: recorder.views[0], in: host), 50)
        XCTAssertEqual(recorder.views[0]?.frame.height, 350)
    }

    private func topEdge(of view: NSView?, in host: NSView) -> CGFloat? {
        guard let view else { return nil }
        let rect = view.convert(view.bounds, to: host)
        return host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
    }
}

@MainActor
private final class DeckTopRecorder {
    var deckTop: CGFloat?
}

private struct DeckTopReader: NSViewRepresentable {
    let recorder: DeckTopRecorder

    func makeNSView(context _: Context) -> NSView { NSView() }

    func updateNSView(_: NSView, context: Context) {
        recorder.deckTop = context.environment.terminalDeckTop
    }
}

@MainActor
private final class DeckRecorder {
    var views: [Int: NSView] = [:]
    var proposals: [Int: [ProposedViewSize]] = [:]
    var creations = 0
}

private struct DeckFixture: View {
    let recorder: DeckRecorder
    let selected: Int

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 300)
            VStack(spacing: 0) {
                Color.clear.frame(height: 50)
                TerminalDeck {
                    ForEach(0..<96, id: \.self) { index in
                        ZStack {
                            DeckProbe(index: index, recorder: recorder)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Color.clear.allowsHitTesting(false)
                        }
                        .opacity(index == selected ? 1 : 0)
                        .allowsHitTesting(index == selected)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

private struct DeckProbe: NSViewRepresentable {
    let index: Int
    let recorder: DeckRecorder

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        recorder.views[index] = view
        recorder.creations += 1
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSView, context _: Context) -> CGSize? {
        recorder.proposals[index, default: []].append(proposal)
        return proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }
}
