import Foundation
import Testing
@testable import agtermCore

struct ControlEventProtocolTests {
    private let run = UUID(uuidString: "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1")!

    @Test func everyEventKindAndPayloadRoundTrips() throws {
        let events = [
            ControlEvent(seq: 1, ts: 1.25, kind: .status, window: "win", workspace: "work", session: "sess",
                         payload: ControlEventPayload(name: "api", status: "blocked", pane: "right",
                                                      blink: true, color: "#aabbcc")),
            ControlEvent(seq: 2, ts: 2.5, kind: .notify, window: "win", workspace: "work", session: "sess",
                         payload: ControlEventPayload(name: "api", title: "Done", body: "tests passed")),
            ControlEvent(seq: 3, ts: 3.5, kind: .sessionCreated, window: "win", workspace: "work",
                         session: "created", payload: ControlEventPayload(name: "new")),
            ControlEvent(seq: 4, ts: 4.5, kind: .sessionClosed, window: "win", workspace: "work",
                         session: "closed", payload: ControlEventPayload(name: "old")),
            ControlEvent(seq: 5, ts: 5.5, kind: .treeChanged, window: "win"),
        ]

        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([ControlEvent].self, from: data)

        #expect(decoded == events)
        let json = String(decoding: data, as: UTF8.self)
        for kind in ControlEventKind.allCases {
            #expect(json.contains("\"kind\":\"" + kind.rawValue + "\""))
        }
    }

    @Test func everyEventKindMatchesGoldenWireShape() throws {
        let events = [
            ControlEvent(seq: 1, ts: 1.25, kind: .status, window: "win", workspace: "work", session: "sess",
                         payload: ControlEventPayload(name: "api", status: "blocked", pane: "right",
                                                      blink: true, color: "#aabbcc")),
            ControlEvent(seq: 2, ts: 2.5, kind: .notify, window: "win", workspace: "work", session: "sess",
                         payload: ControlEventPayload(name: "api", title: "Done", body: "tests passed")),
            ControlEvent(seq: 3, ts: 3.5, kind: .sessionCreated, window: "win", workspace: "work",
                         session: "created", payload: ControlEventPayload(name: "new")),
            ControlEvent(seq: 4, ts: 4.5, kind: .sessionClosed, window: "win", workspace: "work",
                         session: "closed", payload: ControlEventPayload(name: "old")),
            ControlEvent(seq: 5, ts: 5.5, kind: .treeChanged, window: "win"),
        ]
        let expected = [
            ##"{"kind":"status","payload":{"blink":true,"color":"#aabbcc","name":"api","pane":"right","status":"blocked"},"seq":1,"session":"sess","ts":1.25,"window":"win","workspace":"work"}"##,
            ##"{"kind":"notify","payload":{"body":"tests passed","name":"api","title":"Done"},"seq":2,"session":"sess","ts":2.5,"window":"win","workspace":"work"}"##,
            ##"{"kind":"session.created","payload":{"name":"new"},"seq":3,"session":"created","ts":3.5,"window":"win","workspace":"work"}"##,
            ##"{"kind":"session.closed","payload":{"name":"old"},"seq":4,"session":"closed","ts":4.5,"window":"win","workspace":"work"}"##,
            ##"{"kind":"tree.changed","payload":{},"seq":5,"ts":5.5,"window":"win"}"##,
        ]

        #expect(try events.map(canonicalJSON) == expected)
    }

    @Test func optionalEventAndPayloadFieldsAreOmitted() throws {
        let event = ControlEvent(seq: 1, ts: 10, kind: .treeChanged, window: "win")
        let data = try JSONEncoder().encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])

        #expect(object["workspace"] == nil)
        #expect(object["session"] == nil)
        #expect(payload.isEmpty)
    }

    @Test func bootstrapAndPopulatedBatchesRoundTripInResults() throws {
        let bootstrap = ControlEventBatch(run: run, next: 41, items: [])
        let event = ControlEvent(seq: 42, ts: 42.25, kind: .status, window: "win", workspace: "work",
                                 session: "sess", payload: ControlEventPayload(name: "api", status: "active"))
        let populated = ControlEventBatch(run: run, next: 42, items: [event])

        for batch in [bootstrap, populated] {
            let response = ControlResponse(ok: true, result: ControlResult(events: batch))
            let data = try JSONEncoder().encode(response)
            #expect(try JSONDecoder().decode(ControlResponse.self, from: data) == response)
        }
    }

    @Test func errorResponseCanCarryCurrentEventAnchor() throws {
        let anchor = ControlEventBatch(run: run, next: 99, items: [])
        let response = ControlResponse(ok: false, result: ControlResult(events: anchor),
                                       error: ControlEventReadError.cursorExpired.rawValue)

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)

        #expect(decoded == response)
        #expect(decoded.result?.events == anchor)
        #expect(try canonicalJSON(response) ==
            #"{"error":"event cursor expired","ok":false,"result":{"events":{"items":[],"next":99,"run":"CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1"}}}"#)
    }

    @Test func eventReadRequestKeepsKindsAsRawStringsOnTheWire() throws {
        let request = ControlRequest(cmd: .eventsRead,
                                     args: ControlArgs(after: "7", run: run.uuidString,
                                                       kinds: ["status", "future.kind"], limit: 250))

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)

        #expect(decoded == request)
        #expect(decoded.args?.kinds == ["status", "future.kind"])
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
