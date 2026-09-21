import Foundation
import Testing
@testable import agtermCore

struct PresentationLayoutTests {
    @Test(arguments: [false, true])
    func layoutAndSnapshotRoundTrip(split: Bool) throws {
        let primary = UUID()
        let panes = split ? [primary, UUID()] : [primary]
        let layout = PresentationLayout(panes: panes, primary: primary, axis: split ? "horizontal" : nil, shown: split)
        for body: PresentationFrame.Body in [.layout(layout), .snapshot(PresentationSnapshot(status: nil, hud: nil, layout: layout))] {
            let frame = PresentationFrame(gen: 1, rev: 2, body: body)
            #expect(try PresentationCodec.decode(PresentationCodec.encode(frame).dropLast()) == frame)
        }
        #expect(layout.isValid)
    }

    @Test func invalidMembershipCannotBeApplied() {
        let first = UUID()
        let second = UUID()
        let layouts = [
            PresentationLayout(panes: [], primary: first, shown: false),
            PresentationLayout(panes: [first, first], primary: first, axis: "vertical", shown: true),
            PresentationLayout(panes: [first], primary: second, shown: false),
            PresentationLayout(panes: [first, second, UUID()], primary: first, axis: "vertical", shown: true),
            PresentationLayout(panes: [first, second], primary: first, axis: "diagonal", shown: true),
            PresentationLayout(panes: [first, second], primary: first, shown: true),
        ]
        #expect(layouts.allSatisfy { !$0.isValid })
    }

    @Test func olderSnapshotHasNoLayout() throws {
        let frame = try PresentationCodec.decode(Data(#"{"kind":"snapshot","gen":1,"rev":1,"snapshot":{}}"#.utf8))
        #expect(frame.body == .snapshot(PresentationSnapshot(status: nil, hud: nil)))
    }
}

extension RemotePresentationClientTests {
    @Test func layoutPrecedesSnapshotEffectsAndMalformedLayoutsKeepTheLinkUp() {
        let first = UUID()
        let layout = PresentationLayout(panes: [first], primary: first, shown: false)
        var received: [PresentationLayout] = []
        var order: [String] = []
        let effects = RemotePresentationEffects(
            status: { _ in order.append("status") }, snapshotStatus: { _ in order.append("status") },
            hud: { _ in order.append("hud") }, notify: { _ in }, connection: { _ in },
            context: { _ in order.append("context") },
            layout: { received.append($0); order.append("layout") }, warn: { _ in })
        let client = RemotePresentationClient(argv: [], presentationVersion: 1, transport: transport, effects: effects)
        client.start()
        connect(client, snapshot: PresentationSnapshot(status: nil, hud: nil, layout: layout))
        #expect(order == ["layout", "status", "hud", "context"])
        for (index, payload) in [#"{"panes":["bad"],"primary":42,"shown":true}"#, "null", "{}"].enumerated() {
            transport.deliver(Data("{\"kind\":\"layout\",\"gen\":7,\"rev\":\(index + 2),\"layout\":\(payload)}".utf8))
        }
        transport.deliver(Data(#"{"kind":"snapshot","gen":7,"rev":5,"snapshot":{"layout":{"panes":[]}}}"#.utf8))
        #expect(!transport.links[0].stopped)
        #expect(received == [layout])
        transport.deliver(line(.layout(layout), rev: 6))
        #expect(received == [layout, layout])
    }
}
