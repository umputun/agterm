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
        #expect(controller.recentResults.map(\.id) == [pick.id])
        #expect(controller.recentResults.map(\.result) == [outcome])
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

    @Test func pendingPickCarriesQueryAndDefaultsItToNil() {
        let controller = PickController()
        let prefilled = PendingPick(
            id: "prefilled",
            items: [ControlPickItem(id: "one", label: "One")],
            query: "current name"
        )

        #expect(controller.open(prefilled))

        #expect(controller.pending?.query == "current name")
        #expect(makePick(id: "plain").query == nil)
    }

    @Test func resultReturnsNilForUnknownID() {
        let controller = PickController()
        #expect(controller.open(makePick(id: "known")))

        #expect(controller.result(for: "unknown") == nil)
    }

    @Test func nextOpenKeepsPriorResultReadableForItsOwnPoller() {
        let controller = PickController()
        let first = makePick(id: "first")
        let firstResult = ControlPickResult(result: .custom, query: "typed")
        #expect(controller.open(first))
        controller.resolve(firstResult)

        let second = makePick(id: "second")
        #expect(controller.open(second))

        #expect(controller.result(for: first.id) == firstResult)
        #expect(controller.result(for: second.id) == ControlPickResult(result: .pending))
    }

    @Test func retainedResultsStopAtTheLimitDroppingTheOldest() {
        let controller = PickController()
        let total = PickController.retainedResultLimit + 2
        for index in 0..<total {
            #expect(controller.open(makePick(id: "pick-\(index)")))
            controller.resolve(ControlPickResult(result: .picked, id: "one", label: "One", index: index))
        }

        #expect(controller.recentResults.count == PickController.retainedResultLimit)
        #expect(controller.result(for: "pick-0") == nil)
        #expect(controller.result(for: "pick-1") == nil)
        #expect(controller.result(for: "pick-2")?.index == 2)
        #expect(controller.result(for: "pick-\(total - 1)")?.index == total - 1)
    }

    @Test func registryRegistersLooksUpAndUnregisters() {
        let registry = PickRegistry.shared
        let id = UUID()
        let controller = PickController()
        #expect(registry.controller(for: id) == nil)

        registry.register(id, controller: controller)
        #expect(registry.controller(for: id) === controller)

        registry.unregister(id)
        #expect(registry.controller(for: id) == nil)
    }

    @Test func registryUnregisterCancelsAndRetainsResultForItsPollers() {
        let registry = PickRegistry.shared
        let id = UUID()
        let controller = PickController()
        let pick = makePick(id: "closed-window")
        defer { registry.unregister(id) }
        registry.register(id, controller: controller)
        #expect(controller.open(pick))

        registry.unregister(id)

        #expect(registry.controller(for: id) == nil)
        #expect(registry.retainedResult(for: pick.id)?.windowID == id)
        #expect(registry.retainedResult(for: pick.id)?.result == ControlPickResult(result: .cancelled))
    }

    @Test func registryTrimDropsTheOldestAnswerNotTheFirstTransferred() {
        let registry = PickRegistry.shared
        let marker = UUID().uuidString

        // answer the fillers FIRST, so they are the older answers, but leave their windows open.
        let fillers = (0..<PickRegistry.retainedResultLimit).map { index -> (UUID, PickController) in
            let id = UUID()
            let controller = PickController()
            registry.register(id, controller: controller)
            #expect(controller.open(makePick(id: "\(marker)-filler-\(index)")))
            controller.cancel()
            return (id, controller)
        }
        // answer the newest pick AFTER them, and close its window FIRST so it transfers to the front.
        let newestWindow = UUID()
        let newest = PickController()
        registry.register(newestWindow, controller: newest)
        #expect(newest.open(makePick(id: "\(marker)-newest")))
        newest.cancel()
        registry.unregister(newestWindow)

        for (id, _) in fillers { registry.unregister(id) }

        #expect(registry.retainedResult(for: "\(marker)-newest") != nil,
                "trimming must not drop the newest answer just because its window closed first")
        #expect(registry.retainedResult(for: "\(marker)-filler-0") == nil,
                "the oldest answer is the one that goes")
    }

    @Test func registryRetainedResultsStopAtTheLimitDroppingTheOldest() {
        let registry = PickRegistry.shared
        let marker = UUID().uuidString
        let total = PickRegistry.retainedResultLimit + 1
        for index in 0..<total {
            let id = UUID()
            let controller = PickController()
            registry.register(id, controller: controller)
            #expect(controller.open(makePick(id: "\(marker)-\(index)")))
            registry.unregister(id)
        }

        #expect(registry.retainedResult(for: "\(marker)-0") == nil)
        #expect(registry.retainedResult(for: "\(marker)-\(total - 1)") != nil)
    }

    @Test func registryLookupWithNilIDReturnsNil() {
        #expect(PickRegistry.shared.controller(for: nil) == nil)
    }

    @Test func permanentWindowRemovalKeepsRetainedResultForExternalPoll() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-pick-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = WindowLibrary(directory: directory)
        let id = library.newWindow(name: "temporary").id
        let controller = PickController()
        let pick = makePick(id: "deleted-window")
        PickRegistry.shared.register(id, controller: controller)
        #expect(controller.open(pick))
        PickRegistry.shared.unregister(id)
        #expect(PickRegistry.shared.retainedResult(for: pick.id) != nil)

        library.removeWindow(id)

        #expect(PickRegistry.shared.retainedResult(for: pick.id)?.result ==
            ControlPickResult(result: .cancelled))
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
