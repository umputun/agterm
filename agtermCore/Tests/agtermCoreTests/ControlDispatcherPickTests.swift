import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherPickTests {
    @Test func openRejectsMissingItemsWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .pickOpen))
        let missingWithCustom = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(allowCustom: true)
        ))

        let expected = ControlResponse(ok: false, error: "pick.open requires items")
        #expect(missing == expected)
        #expect(missingWithCustom == expected, "allowCustom relaxes an empty list, not an absent one")
        #expect(actions.calls.isEmpty)
    }

    @Test func openRejectsEmptyItemsWithoutAllowCustomWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let empty = await dispatcher.dispatch(ControlRequest(cmd: .pickOpen, args: ControlArgs(items: [])))
        let explicitlyOff = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: [], allowCustom: false)
        ))

        let expected = ControlResponse(ok: false, error: "pick.open requires at least one item")
        #expect(empty == expected)
        #expect(explicitlyOff == expected)
        #expect(actions.calls.isEmpty)
    }

    @Test func openAcceptsEmptyItemsWithAllowCustom() async throws {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true, result: ControlResult(id: "pick-id"))
        actions.nextPickOpenResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: [], prompt: "New name", query: "old name", allowCustom: true)
        ))

        #expect(response == expected)
        let call = try #require(actions.calls.first)
        guard case let .pickOpen(pick, _, _) = call else {
            Issue.record("expected pick.open host call")
            return
        }
        #expect(pick.items.isEmpty)
        #expect(pick.prompt == "New name")
        #expect(pick.query == "old name")
        #expect(pick.allowCustom)
    }

    @Test func openRejectsEmptyLabelWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: [ControlPickItem(id: "empty", label: "")])
        ))

        #expect(response == ControlResponse(ok: false, error: "pick item label must not be empty"))
        #expect(actions.calls.isEmpty)
    }

    @Test func openRejectsDuplicateIDsWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: [
                ControlPickItem(id: "same", label: "One"),
                ControlPickItem(id: "same", label: "Two")
            ])
        ))

        #expect(response == ControlResponse(ok: false, error: "pick item ids must be unique"))
        #expect(actions.calls.isEmpty)
    }

    @Test func openRejectsItemsOverLimitWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let items = (0...ControlPickItem.maxItems).map {
            ControlPickItem(id: "\($0)", label: "Item \($0)")
        }

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: items)
        ))

        #expect(response == ControlResponse(ok: false, error: "too many items (max 1000)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func openStillValidatesNonEmptyItemsWhenAllowCustomIsSet() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let overLimit = (0...ControlPickItem.maxItems).map { ControlPickItem(id: "\($0)", label: "Item \($0)") }

        let capped = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: overLimit, allowCustom: true)
        ))
        let blankLabel = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: [ControlPickItem(id: "empty", label: "")], allowCustom: true)
        ))

        #expect(capped == ControlResponse(ok: false, error: "too many items (max 1000)"))
        #expect(blankLabel == ControlResponse(ok: false, error: "pick item label must not be empty"))
        #expect(actions.calls.isEmpty)
    }

    @Test func openRejectsControlCharactersInLabelAndSubtitleWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let label = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: [ControlPickItem(id: "label", label: "bad\nlabel")])
        ))
        let subtitle = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: [ControlPickItem(id: "subtitle", label: "Good", subtitle: "bad\u{7f}")])
        ))

        let expected = ControlResponse(ok: false, error: "item text must not contain control characters")
        #expect(label == expected)
        #expect(subtitle == expected)
        #expect(actions.calls.isEmpty)
    }

    @Test func resultAndCancelRejectMissingTargetWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let result = await dispatcher.dispatch(ControlRequest(cmd: .pickResult))
        let cancel = await dispatcher.dispatch(ControlRequest(cmd: .pickCancel))

        #expect(result == ControlResponse(ok: false, error: "pick.result requires a pick id"))
        #expect(cancel == ControlResponse(ok: false, error: "pick.cancel requires a pick id"))
        #expect(actions.calls.isEmpty)
    }

    @Test func openRoutesValidatedPickAndReturnsHostResponse() async throws {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true, result: ControlResult(id: "pick-id"))
        actions.nextPickOpenResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)
        let items = [
            ControlPickItem(id: "one", label: "One", subtitle: "First"),
            ControlPickItem(id: "two", label: "Two")
        ]

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(
                follow: true,
                items: items,
                prompt: "Choose",
                allowCustom: true,
                window: "window-id"
            )
        ))

        #expect(response == expected)
        let call = try #require(actions.calls.first)
        guard case let .pickOpen(pick, window, follow) = call else {
            Issue.record("expected pick.open host call")
            return
        }
        #expect(UUID(uuidString: pick.id) != nil)
        #expect(pick.items == items)
        #expect(pick.prompt == "Choose")
        #expect(pick.allowCustom)
        #expect(window == "window-id")
        #expect(follow)
    }

    @Test func openPassesQueryThroughAndLeavesItNilWhenOmitted() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let items = [ControlPickItem(id: "one", label: "One")]

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: items, query: "current name")
        ))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .pickOpen, args: ControlArgs(items: items)))

        #expect(actions.calls.count == 2)
        let seeded = try #require(actions.calls.first)
        let omitted = try #require(actions.calls.last)
        guard case let .pickOpen(withQuery, _, _) = seeded,
              case let .pickOpen(withoutQuery, _, _) = omitted else {
            Issue.record("expected two pick.open host calls")
            return
        }
        #expect(withQuery.query == "current name")
        #expect(withoutQuery.query == nil)
    }

    @Test func resultRoutesTargetAndReturnsNestedPickResponse() async {
        let actions = MockControlActions()
        let pick = ControlPickResult(result: .picked, id: "two", label: "Two", index: 1)
        let expected = ControlResponse(ok: true, result: ControlResult(pick: pick))
        actions.nextPickResultResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .pickResult,
            target: "pick-id",
            args: ControlArgs(window: "window-id")
        ))

        #expect(response == expected)
        #expect(actions.calls == [.pickResult(target: "pick-id", window: "window-id")])
    }

    @Test func cancelRoutesTargetAndReturnsSuccessResponse() async {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true)
        actions.nextPickCancelResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .pickCancel,
            target: "pick-id",
            args: ControlArgs(window: "window-id")
        ))

        #expect(response == expected)
        #expect(actions.calls == [.pickCancel(target: "pick-id", window: "window-id")])
    }
}
