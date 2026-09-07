import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AskTests {
    @Test(arguments: ControlAskStyle.allCases)
    func sharedRegistryLooksUpLiveOwnerAndRetainsAfterOwnerDisappears(style: ControlAskStyle) {
        let windowID = UUID()
        let session = Session(initialCwd: "/tmp")
        let controller = PickController()
        let ask = PendingAsk(id: UUID().uuidString, title: "Continue?", buttons: buttons(count: 1), style: style)
        let owner: AskRegistry.Owner = style == .terminal ? .session(session.id, window: windowID) : .window(windowID)
        let registry = AskRegistry { candidate in
            guard candidate == owner else { return nil }
            return style == .terminal ? session.askPending : controller.pendingAsk
        }
        #expect(style == .terminal ? session.openAsk(ask) : controller.openAsk(ask))
        #expect(registry.register(id: ask.id, owner: owner))
        #expect(registry.owner(for: ask.id) == owner)
        #expect(registry.result(for: ask.id)?.result == ControlAskResult(result: .pending))
        #expect(registry.result(for: ask.id)?.windowID == windowID)
        #expect(registry.result(for: "unknown") == nil)

        let answer = ControlAskResult(result: .answered, id: "button-0", label: "Button 0", index: 0)
        #expect(registry.retain(id: ask.id, result: answer, window: windowID))
        if style == .terminal { session.resolveAsk(id: ask.id, answer) } else { controller.resolveAsk(answer) }
        registry.resolveOwner = { _ in nil }
        #expect(registry.owner(for: ask.id) == nil)
        #expect(registry.result(for: ask.id)?.result == answer)
        #expect(registry.result(for: ask.id)?.windowID == windowID)
    }

    @Test func sessionResolutionRetainsItsRegisteredOutcomeSynchronously() {
        let registry = AskRegistry.shared
        let previousResolver = registry.resolveOwner
        defer { registry.resolveOwner = previousResolver }
        let session = Session(initialCwd: "/tmp")
        let windowID = UUID()
        let ask = makeAsk(id: UUID().uuidString)
        let owner = AskRegistry.Owner.session(session.id, window: windowID)
        registry.resolveOwner = { candidate in
            candidate == owner ? session.askPending : previousResolver(candidate)
        }
        #expect(session.openAsk(ask))
        #expect(registry.register(id: ask.id, owner: owner))
        #expect(registry.result(for: ask.id)?.result.result == .pending)

        #expect(session.cancelAsk(id: ask.id))

        #expect(session.askPending == nil)
        #expect(registry.owner(for: ask.id) == nil)
        #expect(registry.result(for: ask.id)?.result == ControlAskResult(result: .cancelled))
        #expect(registry.result(for: ask.id)?.windowID == windowID)
        #expect(!session.cancelAsk(id: ask.id))
        #expect(registry.result(for: ask.id)?.result.result == .cancelled)
    }

    @Test func registryRejectsDuplicateIDsWrongWindowsAndNonterminalRetention() {
        let controller = PickController()
        let windowID = UUID()
        let ask = makeAsk(id: "original")
        let owner = AskRegistry.Owner.window(windowID)
        let registry = AskRegistry { _ in controller.pendingAsk }
        #expect(controller.openAsk(ask))
        #expect(registry.register(id: ask.id, owner: owner))
        #expect(!registry.register(id: ask.id, owner: .window(UUID())))
        #expect(registry.owner(for: ask.id) == owner)
        #expect(!registry.retain(id: ask.id, result: ControlAskResult(result: .pending), window: windowID))
        #expect(!registry.retain(id: ask.id, result: ControlAskResult(result: .cancelled), window: UUID()))
        #expect(registry.result(for: ask.id)?.result.result == .pending)

        #expect(registry.retain(id: ask.id, result: ControlAskResult(result: .escaped), window: windowID))
        #expect(!registry.retain(id: ask.id, result: ControlAskResult(result: .cancelled), window: windowID))
        #expect(!registry.register(id: ask.id, owner: owner))
        #expect(registry.result(for: ask.id)?.result.result == .escaped)
    }

    @Test func registryDoesNotMistakeTheOwnersNextAskForTheRegisteredID() {
        let controller = PickController()
        let registry = AskRegistry { _ in controller.pendingAsk }
        #expect(registry.register(id: "first", owner: .window(UUID())))
        #expect(registry.result(for: "first") == nil)
        #expect(controller.openAsk(makeAsk(id: "first")))
        #expect(registry.result(for: "first")?.result.result == .pending)
        controller.cancelAsk()
        #expect(controller.openAsk(makeAsk(id: "next")))
        #expect(registry.result(for: "first") == nil)
        #expect(registry.result(for: "next") == nil)
    }

    @Test func registryEvictsByResolutionOrderAndNeverEvictsPendingAsks() {
        let windowIDs = (0..<(AskRegistry.retainedResultLimit + 3)).map { _ in UUID() }
        var controllers: [UUID: PickController] = [:]
        let registry = AskRegistry { controllers[$0.windowID]?.pendingAsk }
        for (index, windowID) in windowIDs.enumerated() {
            let controller = PickController()
            controllers[windowID] = controller
            #expect(controller.openAsk(makeAsk(id: "ask-\(index)")))
            #expect(registry.register(id: "ask-\(index)", owner: .window(windowID)))
        }
        for index in windowIDs.indices {
            #expect(registry.result(for: "ask-\(index)")?.result.result == .pending)
        }
        for index in windowIDs.indices.dropFirst().reversed() {
            #expect(registry.retain(id: "ask-\(index)", result: ControlAskResult(result: .cancelled), window: windowIDs[index]))
            controllers[windowIDs[index]]?.cancelAsk()
            controllers[windowIDs[index]] = nil
        }

        #expect(registry.result(for: "ask-0")?.result.result == .pending)
        #expect(registry.owner(for: "ask-0") == .window(windowIDs[0]))
        for index in 1...AskRegistry.retainedResultLimit {
            #expect(registry.result(for: "ask-\(index)")?.result.result == .cancelled)
            #expect(registry.result(for: "ask-\(index)")?.windowID == windowIDs[index])
        }
        #expect(registry.result(for: "ask-\(AskRegistry.retainedResultLimit + 1)") == nil)
        #expect(registry.result(for: "ask-\(AskRegistry.retainedResultLimit + 2)") == nil)
    }

    @Test func guiAskKeepsItsAnchorAndExcludesPicks() {
        let controller = PickController()
        let anchor = AskAnchor(sessionID: UUID(), pane: .right, paneIdentity: UUID())
        let ask = PendingAsk(id: UUID().uuidString, title: "Continue?", buttons: buttons(count: 1), style: .gui, anchor: anchor)
        #expect(controller.openAsk(ask))
        #expect(controller.pendingAsk == ask)
        #expect(controller.askResult(for: ask.id)?.result == .pending)
        #expect(!controller.openAsk(makeAsk(id: UUID().uuidString)))
        #expect(!controller.open(PendingPick(id: "pick", items: [])))
        controller.cancelAsk()
        #expect(controller.pendingAsk == nil)
        #expect(controller.open(PendingPick(id: "pick", items: [])))
        #expect(!controller.openAsk(ask))
    }

    @Test(arguments: [1, 6])
    func navigationWithoutDefaultAnswersFirstNonDestructiveButton(count: Int) {
        let navigation = AskNavigation(buttons: buttons(count: count), destructiveID: "button-0")
        #expect(navigation.highlighted == (count == 1 ? 0 : 1))
        #expect(navigation.activate() == (count == 1 ? 0 : 1))
    }

    @Test(arguments: [(1, "button-0", 0), (6, "button-4", 4)])
    func navigationSeedsHighlightFromDefault(count: Int, defaultID: String, expectedIndex: Int) {
        let navigation = AskNavigation(buttons: buttons(count: count), defaultID: defaultID)
        #expect(navigation.highlighted == expectedIndex)
        #expect(navigation.activate() == expectedIndex)
    }

    @Test(arguments: [(1, [0, 0]), (6, [1, 2, 3, 4, 5, 0, 1])])
    func forwardNavigationAdvancesAndWraps(count: Int, expectedIndices: [Int]) {
        var navigation = AskNavigation(buttons: buttons(count: count))
        for expected in expectedIndices {
            navigation.moveForward()
            #expect(navigation.highlighted == expected)
            #expect(navigation.activate() == expected)
        }
    }

    @Test(arguments: [(1, [0, 0]), (6, [5, 4, 3, 2, 1, 0, 5])])
    func backwardNavigationWrapsToLast(count: Int, expectedIndices: [Int]) {
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
    func hotkeysAreCaseInsensitiveAndIndependentOfHighlight(letter: String, expectedIndex: Int) {
        let navigation = AskNavigation(buttons: [
            ControlAskButton(id: "yes", label: "Yes", hotkey: "Y"),
            ControlAskButton(id: "no", label: "No", hotkey: "n"),
        ])
        #expect(navigation.hotkey(letter) == expectedIndex)
        #expect(navigation.highlighted == 0)
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
        ], destructiveID: "delete")
        var navigation = AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID, destructiveID: ask.destructiveID)
        #expect(navigation.activate() == 0)
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
