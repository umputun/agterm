import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct EventCommandsTests {
    private let run = UUID(uuidString: "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1")!

    @Test func parserBuildsBootstrapAndCursoredRequests() throws {
        let plain = try Events.parse([])
        #expect(try plain.makeInitialRequest() == ControlRequest(cmd: .eventsRead))

        let resumed = try Events.parse([
            "--json", "--kind", "status,notify", "--kind", "tree.changed",
            "--run", run.uuidString, "--after", "42", "--limit", "1000",
        ])
        #expect(resumed.options.json)
        #expect(try resumed.makeInitialRequest() == ControlRequest(
            cmd: .eventsRead,
            args: ControlArgs(after: "42", run: run.uuidString,
                              kinds: ["status", "notify", "tree.changed"], limit: 1_000)
        ))
    }

    @Test func parserRejectsInvalidPairsKindsAndLimits() {
        for argv in [
            ["--run", run.uuidString], ["--after", "1"], ["--run", "bad", "--after", "1"],
            ["--run", run.uuidString, "--after", "-1"], ["--kind", "future"],
            ["--kind", ""], ["--kind", ","], ["--kind", "status,"],
            ["--limit", "0"], ["--limit", "1001"],
        ] {
            #expect(throws: (any Error).self) { try Events.parse(argv) }
        }
    }

    @Test func streamStateBootstrapsAndAdvancesCursor() throws {
        var state = EventStreamState(kinds: [.status], limit: 2)
        #expect(state.makeRequest() == ControlRequest(cmd: .eventsRead,
                                                     args: ControlArgs(kinds: ["status"], limit: 2)))

        let empty = ControlEventBatch(run: run, next: 5, items: [])
        let emptyEvents = try state.consume(ControlResponse(ok: true, result: ControlResult(events: empty)))
        #expect(emptyEvents.isEmpty)
        #expect(state.makeRequest().args?.after == "5")
        #expect(state.makeRequest().args?.run == run.uuidString)

        let event = ControlEvent(seq: 6, ts: 10, kind: .status,
                                 payload: ControlEventPayload(name: "api", status: "active"))
        let page = ControlEventBatch(run: run, next: 6, items: [event])
        let pageEvents = try state.consume(ControlResponse(ok: true, result: ControlResult(events: page)))
        #expect(pageEvents == [event])
        #expect(state.makeRequest().args?.after == "6")
    }

    @Test func runPollsEmptyPagesWritesNDJSONImmediatelyAndResumesFromCursor() throws {
        let event = ControlEvent(seq: 6, ts: 10, kind: .status,
                                 payload: ControlEventPayload(name: "api", status: "active"))
        var responses = [
            ControlResponse(ok: true, result: ControlResult(events: ControlEventBatch(run: run, next: 5, items: []))),
            ControlResponse(ok: true, result: ControlResult(events: ControlEventBatch(run: run, next: 6, items: [event]))),
        ]
        var requests: [ControlRequest] = []
        var sleeps: [TimeInterval] = []
        var lines: [String] = []
        let dependencies = EventStreamDependencies(
            send: { request in
                requests.append(request)
                return responses.removeFirst()
            },
            sleep: { sleeps.append($0) },
            writeLine: { lines.append($0) }
        )
        let command = try Events.parse(["--json"])
        var state = command.makeState()

        try command.poll(state: &state, dependencies: dependencies)
        try command.poll(state: &state, dependencies: dependencies)

        #expect(requests.count == 2)
        #expect(requests[0] == ControlRequest(cmd: .eventsRead))
        #expect(requests[1].args?.run == run.uuidString)
        #expect(requests[1].args?.after == "5")
        #expect(sleeps == [0.25])
        #expect(lines.count == 1)
        #expect(!lines[0].contains("\n"))
        #expect(try JSONDecoder().decode(ControlEvent.self, from: Data(lines[0].utf8)) == event)
    }

    @Test func runStopsImmediatelyOnTransportServerAndOutputFailures() throws {
        let command = try Events.parse([])
        var transportState = command.makeState()
        var transportSends = 0
        #expect(throws: EventStreamError.self) {
            try command.poll(state: &transportState, dependencies: EventStreamDependencies(
                send: { _ in
                    transportSends += 1
                    throw EventStreamError("transport failed")
                }, sleep: { _ in }, writeLine: { _ in }
            ))
        }
        #expect(transportSends == 1)

        var serverState = command.makeState()
        var serverSends = 0
        #expect(throws: EventStreamError.self) {
            try command.poll(state: &serverState, dependencies: EventStreamDependencies(
                send: { _ in
                    serverSends += 1
                    return ControlResponse(ok: false, error: ControlEventReadError.cursorExpired.rawValue)
                }, sleep: { _ in }, writeLine: { _ in }
            ))
        }
        #expect(serverSends == 1)

        var outputState = command.makeState()
        var outputSends = 0
        #expect(throws: EventStreamError.self) {
            try command.poll(state: &outputState, dependencies: EventStreamDependencies(
                send: { _ in
                    outputSends += 1
                    let event = ControlEvent(seq: 1, ts: 0, kind: .treeChanged)
                    return ControlResponse(ok: true, result: ControlResult(
                        events: ControlEventBatch(run: run, next: 1, items: [event])
                    ))
                }, sleep: { _ in }, writeLine: { _ in throw EventStreamError("output failed") }
            ))
        }
        #expect(outputSends == 1)
    }

    @Test func streamStatePreservesSuppliedCursorAndRejectsServerFailures() throws {
        var state = EventStreamState(cursor: ControlEventCursor(run: run, after: 9), kinds: nil, limit: nil)
        #expect(state.makeRequest().args?.after == "9")
        #expect(throws: EventStreamError.self) {
            try state.consume(ControlResponse(ok: false, error: ControlEventReadError.cursorExpired.rawValue))
        }
        #expect(throws: EventStreamError.self) {
            try state.consume(ControlResponse(ok: true))
        }
    }

    @Test func formattersCoverEveryKindAndNDJSONIsOneBareEvent() throws {
        let events = [
            ControlEvent(seq: 1, ts: 0, kind: .status,
                         payload: ControlEventPayload(name: "api", status: "blocked", pane: "right", blink: true)),
            ControlEvent(seq: 2, ts: 0, kind: .notify,
                         payload: ControlEventPayload(name: "api", title: "Done", body: "ok")),
            ControlEvent(seq: 3, ts: 0, kind: .sessionCreated, payload: ControlEventPayload(name: "new")),
            ControlEvent(seq: 4, ts: 0, kind: .sessionClosed, payload: ControlEventPayload(name: "old")),
            ControlEvent(seq: 5, ts: 0, kind: .treeChanged, window: "win"),
        ]
        let human = events.map { EventFormatter.human($0, timeZone: TimeZone(secondsFromGMT: 0)!) }
        #expect(human[0] == "00:00:00 status api blocked pane=right blink")
        #expect(human[1] == "00:00:00 notify api Done: ok")
        #expect(human[2] == "00:00:00 session.created new")
        #expect(human[3] == "00:00:00 session.closed old")
        #expect(human[4] == "00:00:00 tree.changed win")

        for event in events {
            let line = try EventFormatter.json(event)
            #expect(!line.contains("\n"))
            #expect(try JSONDecoder().decode(ControlEvent.self, from: Data(line.utf8)) == event)
        }
    }
}
