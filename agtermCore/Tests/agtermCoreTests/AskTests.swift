import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AskTests {
    @Test func openCarriesDialogFieldsAndReservesModalSlot() {
        let controller = PickController()
        let anchor = AskAnchor(sessionID: UUID(), pane: .right, paneIdentity: UUID())
        let ask = PendingAsk(
            id: "anchored", title: "Save changes?", message: "Changes have not been saved.",
            buttons: buttons(count: 3), defaultID: "button-0", cancelID: "button-1",
            destructiveID: "button-2", anchor: anchor
        )

        #expect(!controller.modalPending)
        #expect(controller.openAsk(ask))
        #expect(controller.modalPending)
        #expect(controller.pendingAsk == ask)
        #expect(controller.pending == nil)
        #expect(controller.askResult(for: ask.id) == ControlAskResult(result: .pending))
        #expect(controller.askResult(for: "unknown") == nil)
        #expect(controller.result(for: ask.id) == nil)
    }

    @Test func resolveRetainsTheAnswerAndReleasesModalSlot() {
        let controller = PickController()
        let ask = makeAsk(id: "answered")
        let answer = ControlAskResult(result: .answered, id: "button-0", label: "Button 0", index: 0)
        #expect(controller.openAsk(ask))

        controller.resolveAsk(answer)

        #expect(!controller.modalPending)
        #expect(controller.pendingAsk == nil)
        #expect(controller.recentAskResults.map(\.id) == [ask.id])
        #expect(controller.recentAskResults.map(\.result) == [answer])
        #expect(controller.askResult(for: ask.id) == answer)
        controller.cancelAsk()
        #expect(controller.askResult(for: ask.id) == answer)
    }

    @Test func cancelDoesNotAnswerTheNamedCancelButton() {
        let controller = PickController()
        let ask = PendingAsk(id: "cancelled", title: "Continue?", buttons: buttons(count: 1),
                             cancelID: "button-0")
        #expect(controller.openAsk(ask))

        controller.cancelAsk()
        controller.cancelAsk()

        #expect(controller.pendingAsk == nil)
        #expect(!controller.modalPending)
        #expect(controller.recentAskResults.count == 1)
        #expect(controller.askResult(for: ask.id) == ControlAskResult(result: .cancelled))
    }

    @Test func openRejectsWhileAnotherAskIsPending() {
        let controller = PickController()
        let first = makeAsk(id: "first")
        #expect(controller.openAsk(first))
        #expect(!controller.openAsk(makeAsk(id: "second")))
        #expect(controller.pendingAsk == first)
        #expect(controller.askResult(for: "second") == nil)
    }

    @Test func askRejectsWhilePickOwnsModalSlot() {
        let controller = PickController()
        let pick = PendingPick(id: "pick", items: [ControlPickItem(id: "one", label: "One")])
        #expect(controller.open(pick))
        #expect(controller.modalPending)
        #expect(!controller.openAsk(makeAsk(id: "ask")))
        #expect(controller.pending == pick)
        #expect(controller.pendingAsk == nil)

        controller.cancelAsk()
        #expect(controller.pending == pick)
        controller.cancel()
        #expect(controller.openAsk(makeAsk(id: "ask")))
    }

    @Test func nextAskKeepsPriorAnswerReadableByID() {
        let controller = PickController()
        #expect(controller.openAsk(makeAsk(id: "first")))
        controller.cancelAsk()
        #expect(controller.openAsk(makeAsk(id: "second")))

        #expect(controller.askResult(for: "first") == ControlAskResult(result: .cancelled))
        #expect(controller.askResult(for: "second") == ControlAskResult(result: .pending))
    }

    @Test func retainedAnswersDropOldestAtControllerLimit() {
        let controller = PickController()
        for index in 0..<(PickController.retainedResultLimit + 2) {
            #expect(controller.openAsk(makeAsk(id: "ask-\(index)")))
            controller.cancelAsk()
        }

        #expect(controller.recentAskResults.count == PickController.retainedResultLimit)
        #expect(controller.askResult(for: "ask-0") == nil)
        #expect(controller.askResult(for: "ask-1") == nil)
        #expect(controller.askResult(for: "ask-2") == ControlAskResult(result: .cancelled))
        #expect(controller.recentAskResults.last?.id == "ask-9")
    }

    @Test func registryFindsPendingAndAnsweredAsksByID() {
        let registry = PickRegistry.shared
        let windowID = UUID()
        let controller = PickController()
        let ask = makeAsk(id: UUID().uuidString)
        registry.register(windowID, controller: controller)
        defer { registry.unregister(windowID) }
        #expect(controller.openAsk(ask))

        #expect(registry.liveAsk(for: ask.id)?.windowID == windowID)
        #expect(registry.liveAsk(for: ask.id)?.controller === controller)
        #expect(registry.livePick(for: ask.id) == nil)
        #expect(registry.retainedAskResult(for: ask.id) == nil)
        #expect(registry.liveAsk(for: UUID().uuidString) == nil)
        controller.cancelAsk()
        #expect(registry.liveAsk(for: ask.id)?.controller === controller)
    }

    @Test func unregisterCancelsAskAndRetainsBothFamilies() {
        let registry = PickRegistry.shared
        let windowID = UUID()
        let controller = PickController()
        let pickID = UUID().uuidString
        let askID = UUID().uuidString
        registry.register(windowID, controller: controller)
        #expect(controller.open(PendingPick(id: pickID, items: [ControlPickItem(id: "one", label: "One")])))
        controller.cancel()
        #expect(controller.openAsk(PendingAsk(id: askID, title: "Continue?", buttons: buttons(count: 1),
                                             cancelID: "button-0")))

        registry.unregister(windowID)
        registry.unregister(windowID)

        #expect(registry.controller(for: windowID) == nil)
        #expect(registry.liveAsk(for: askID) == nil)
        #expect(!controller.modalPending)
        #expect(registry.retainedAskResult(for: askID)?.windowID == windowID)
        #expect(registry.retainedAskResult(for: askID)?.result == ControlAskResult(result: .cancelled))
        #expect(registry.retainedResult(for: pickID)?.result == ControlPickResult(result: .cancelled))
        #expect(registry.retainedAskResult(for: UUID().uuidString) == nil)
    }

    @Test func registryTrimsOldestResolutionEvenWhenItsWindowClosesLast() {
        let registry = PickRegistry.shared
        let marker = UUID().uuidString
        let olderWindows = (0..<PickRegistry.retainedResultLimit).map { index -> UUID in
            let windowID = UUID()
            let controller = PickController()
            registry.register(windowID, controller: controller)
            #expect(controller.openAsk(makeAsk(id: "\(marker)-\(index)")))
            controller.cancelAsk()
            return windowID
        }
        let newestWindow = UUID()
        let newest = PickController()
        let answer = ControlAskResult(result: .answered, id: "button-0", label: "Button 0", index: 0)
        registry.register(newestWindow, controller: newest)
        #expect(newest.openAsk(makeAsk(id: "\(marker)-newest")))
        newest.resolveAsk(answer)

        registry.unregister(newestWindow)
        for windowID in olderWindows { registry.unregister(windowID) }

        #expect(registry.retainedAskResult(for: "\(marker)-0") == nil)
        #expect(registry.retainedAskResult(for: "\(marker)-1") != nil)
        #expect(registry.retainedAskResult(for: "\(marker)-newest")?.result == answer)
    }

    @Test(arguments: [1, 6])
    func navigationWithoutDefaultLeavesReturnInert(count: Int) {
        let navigation = AskNavigation(buttons: buttons(count: count))
        #expect(navigation.highlighted == nil)
        #expect(navigation.activate() == nil)
    }

    @Test(arguments: [(1, "button-0", 0), (6, "button-4", 4)])
    func navigationSeedsHighlightFromDefault(count: Int, defaultID: String, expectedIndex: Int) {
        let navigation = AskNavigation(buttons: buttons(count: count), defaultID: defaultID)
        #expect(navigation.highlighted == expectedIndex)
        #expect(navigation.activate() == expectedIndex)
    }

    @Test(arguments: [(1, [0, 0]), (6, [0, 1, 2, 3, 4, 5, 0])])
    func forwardNavigationEntersFirstAndWraps(count: Int, expectedIndices: [Int]) {
        var navigation = AskNavigation(buttons: buttons(count: count))
        for expected in expectedIndices {
            navigation.moveForward()
            #expect(navigation.highlighted == expected)
            #expect(navigation.activate() == expected)
        }
    }

    @Test(arguments: [(1, [0, 0]), (6, [5, 4, 3, 2, 1, 0, 5])])
    func backwardNavigationEntersLastAndWraps(count: Int, expectedIndices: [Int]) {
        var navigation = AskNavigation(buttons: buttons(count: count))
        for expected in expectedIndices {
            navigation.moveBackward()
            #expect(navigation.highlighted == expected)
            #expect(navigation.activate() == expected)
        }
    }

    @Test func navigationMovesAwayFromDefault() {
        var navigation = AskNavigation(buttons: buttons(count: 6), defaultID: "button-2")
        navigation.moveForward()
        #expect(navigation.activate() == 3)
        navigation.moveBackward()
        #expect(navigation.activate() == 2)
    }

    @Test(arguments: [("y", 0), ("Y", 0), ("n", 1), ("N", 1)])
    func hotkeysAreCaseInsensitiveAndNeedNoHighlight(letter: String, expectedIndex: Int) {
        let navigation = AskNavigation(buttons: [
            ControlAskButton(id: "yes", label: "Yes", hotkey: "Y"),
            ControlAskButton(id: "no", label: "No", hotkey: "n"),
        ])
        #expect(navigation.hotkey(letter) == expectedIndex)
        #expect(navigation.highlighted == nil)
    }

    @Test func undeclaredHotkeyDoesNotMatchALabelOrChangeSelection() {
        let navigation = AskNavigation(buttons: [
            ControlAskButton(id: "yes", label: "Yes"),
            ControlAskButton(id: "no", label: "No", hotkey: "n"),
        ], defaultID: "no")
        #expect(navigation.hotkey("y") == nil)
        #expect(navigation.hotkey("") == nil)
        #expect(navigation.activate() == 1)
    }

    @Test func destructiveChoiceRemainsReachableAfterDeliberateNavigation() {
        let ask = PendingAsk(id: "delete", title: "Delete?", buttons: [
            ControlAskButton(id: "cancel", label: "Cancel"),
            ControlAskButton(id: "delete", label: "Delete", hotkey: "d"),
        ], cancelID: "cancel", destructiveID: "delete")
        var navigation = AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID)
        #expect(navigation.activate() == nil)
        navigation.moveBackward()
        #expect(navigation.activate() == 1)
        #expect(navigation.hotkey("d") == 1)
    }

    @Test func emptyNavigationRemainsInert() {
        var navigation = AskNavigation(buttons: [])
        navigation.moveForward()
        navigation.moveBackward()
        #expect(navigation.activate() == nil)
        #expect(navigation.hotkey("a") == nil)
    }

    private func makeAsk(id: String) -> PendingAsk {
        PendingAsk(id: id, title: "Choose", buttons: buttons(count: 1))
    }

    private func buttons(count: Int) -> [ControlAskButton] {
        (0..<count).map { ControlAskButton(id: "button-\($0)", label: "Button \($0)") }
    }
}
