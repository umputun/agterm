import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlEventDispatcherTests {
    private let run = UUID(uuidString: "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1")!

    @Test func bootstrapRoutesWithDefaultsAndReturnsActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let batch = ControlEventBatch(run: run, next: 12, items: [])
        actions.nextEventsReadResponse = ControlResponse(ok: true, result: ControlResult(events: batch))

        let response = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead))

        #expect(response == actions.nextEventsReadResponse)
        #expect(actions.calls == [.eventsRead(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100))])
    }

    @Test func parsesCursorKindsAndMaximumLimit() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .eventsRead,
            args: ControlArgs(after: "42", run: run.uuidString,
                              kinds: ["status, notify", "tree.changed", "status"], limit: 1_000)
        ))

        let expected = ControlEventReadOptions(
            cursor: ControlEventCursor(run: run, after: 42),
            kinds: [.status, .notify, .treeChanged],
            limit: 1_000
        )
        #expect(actions.calls == [.eventsRead(expected)])
    }

    @Test func cursorFieldsMustBePaired() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let runOnly = await dispatcher.dispatch(ControlRequest(
            cmd: .eventsRead, args: ControlArgs(run: run.uuidString)
        ))
        let afterOnly = await dispatcher.dispatch(ControlRequest(
            cmd: .eventsRead, args: ControlArgs(after: "1")
        ))

        #expect(runOnly == ControlResponse(ok: false, error: "events.read requires --run and --after together"))
        #expect(afterOnly == ControlResponse(ok: false, error: "events.read requires --run and --after together"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsInvalidRunAndDecimalCursor() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let badRun = await dispatcher.dispatch(ControlRequest(
            cmd: .eventsRead, args: ControlArgs(after: "1", run: "not-a-uuid")
        ))
        let badCursor = await dispatcher.dispatch(ControlRequest(
            cmd: .eventsRead, args: ControlArgs(after: "-1", run: run.uuidString)
        ))

        #expect(badRun == ControlResponse(ok: false, error: "invalid event run id"))
        #expect(badCursor == ControlResponse(ok: false, error: "invalid event cursor"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsUnknownKindAfterRawRequestDecoding() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let json = """
        {"cmd":"events.read","args":{"kinds":["status","future.kind"]}}
        """
        let request = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))

        let response = await dispatcher.dispatch(request)

        #expect(response == ControlResponse(ok: false, error: "invalid event kind: future.kind"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsEmptyKindComponents() async {
        for kinds in [[""], [","], ["status,"]] {
            let actions = MockControlActions()
            let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
                cmd: .eventsRead, args: ControlArgs(kinds: kinds)
            ))

            #expect(response == ControlResponse(ok: false, error: "invalid event kind: "))
            #expect(actions.calls.isEmpty)
        }
    }

    @Test func rejectsLimitsOutsideInclusiveBounds() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let zero = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead, args: ControlArgs(limit: 0)))
        let tooLarge = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead, args: ControlArgs(limit: 1_001)))

        #expect(zero == ControlResponse(ok: false, error: "event limit must be between 1 and 1000"))
        #expect(tooLarge == ControlResponse(ok: false, error: "event limit must be between 1 and 1000"))
        #expect(actions.calls.isEmpty)
    }
}
