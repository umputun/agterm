import Foundation
import Testing
@testable import agtermCore

@MainActor
struct PickTests {
    @Test func openAndResolveRetainsResultAfterPendingCloses() throws {
        let controller = PickController()
        let pick = makePick(id: "pick-1")
        let outcome = ControlPickResult(result: .picked, id: "one", label: "One", index: 0)

        #expect(controller.open(pick))
        #expect(controller.pending == pick)
        #expect(controller.result(for: pick.id) == ControlPickResult(result: .pending))

        controller.resolve(outcome)

        #expect(controller.pending == nil)
        #expect(controller.lastResult == ResolvedPick(id: pick.id, result: outcome))
        #expect(controller.result(for: pick.id) == outcome)
    }

    @Test func cancelRetainsCancelledResult() {
        let controller = PickController()
        let pick = makePick(id: "pick-cancel")

        #expect(controller.open(pick))
        controller.cancel()

        #expect(controller.pending == nil)
        #expect(controller.result(for: pick.id) == ControlPickResult(result: .cancelled))
    }

    @Test func openRejectsWhileAnotherPickIsPending() {
        let controller = PickController()
        let first = makePick(id: "first")
        let second = makePick(id: "second")

        #expect(controller.open(first))
        #expect(!controller.open(second))
        #expect(controller.pending == first)
        #expect(controller.result(for: "second") == nil)
    }

    @Test func resultReturnsNilForUnknownID() {
        let controller = PickController()
        #expect(controller.open(makePick(id: "known")))

        #expect(controller.result(for: "unknown") == nil)
    }

    @Test func nextOpenReplacesLastResult() {
        let controller = PickController()
        let first = makePick(id: "first")
        let firstResult = ControlPickResult(result: .custom, query: "typed")
        #expect(controller.open(first))
        controller.resolve(firstResult)
        #expect(controller.lastResult == ResolvedPick(id: first.id, result: firstResult))

        let second = makePick(id: "second")
        #expect(controller.open(second))

        #expect(controller.lastResult == nil)
        #expect(controller.result(for: first.id) == nil)
        #expect(controller.result(for: second.id) == ControlPickResult(result: .pending))
    }

    @Test func registryRegistersLooksUpAndUnregisters() {
        let registry = PickRegistry.shared
        let id = UUID()
        let controller = PickController()
        defer { registry.clearRetainedResult(for: id) }
        #expect(registry.controller(for: id) == nil)

        registry.register(id, controller: controller)
        #expect(registry.controller(for: id) === controller)

        registry.unregister(id)
        #expect(registry.controller(for: id) == nil)
    }

    @Test func registryUnregisterCancelsAndRetainsResultUntilNextOpen() {
        let registry = PickRegistry.shared
        let id = UUID()
        let controller = PickController()
        let pick = makePick(id: "closed-window")
        defer {
            registry.unregister(id)
            registry.clearRetainedResult(for: id)
        }
        registry.register(id, controller: controller)
        #expect(controller.open(pick))

        registry.unregister(id)

        #expect(registry.controller(for: id) == nil)
        #expect(registry.retainedResult(for: pick.id) == ControlPickResult(result: .cancelled))

        registry.clearRetainedResult(for: id)
        #expect(registry.retainedResult(for: pick.id) == nil)
    }

    @Test func registryLookupWithNilIDReturnsNil() {
        #expect(PickRegistry.shared.controller(for: nil) == nil)
    }

    private func makePick(id: String) -> PendingPick {
        PendingPick(
            id: id,
            items: [ControlPickItem(id: "one", label: "One")],
            prompt: "Choose",
            allowCustom: true
        )
    }
}
