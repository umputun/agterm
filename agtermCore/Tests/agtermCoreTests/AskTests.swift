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

    @Test(arguments: [
        (UInt16(31), "щ", "o"), (31, "Щ", "o"), (12, ";", "q"), (12, "/", "q"), (18, "&", nil), (10, "\\", nil),
    ] as [(UInt16, String?, String?)])
    func hotkeyOnANonLatinLayoutResolvesByUSPosition(keyCode: UInt16, produced: String?, expected: String?) {
        #expect(AskNavigation.resolvedHotkey(forKeyCode: keyCode, produced: produced, layoutIsASCIICapable: false) == expected)
    }

    @Test(arguments: [
        (UInt16(12), "a", "a"), (0, "A", "a"), (18, "1", nil), (44, "/", nil), (19, "é", nil), (31, nil, nil),
    ] as [(UInt16, String?, String?)])
    func hotkeyOnALatinLayoutResolvesByTypedLetter(keyCode: UInt16, produced: String?, expected: String?) {
        #expect(AskNavigation.resolvedHotkey(forKeyCode: keyCode, produced: produced, layoutIsASCIICapable: true) == expected)
    }

    private func makeAsk(id: String) -> PendingAsk {
        PendingAsk(id: id, title: "Choose", buttons: buttons(count: 1))
    }

    @Test func aPresentationLostCancelEncodesItsReasonBesideTheOutcome() throws {
        let result = ControlAskResult(result: .cancelled, reason: ControlAskResult.presentationLost)

        let fields = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(result)) as? [String: Any])

        #expect(fields["result"] as? String == "cancelled")
        #expect(fields["reason"] as? String == "presentation-lost")
    }

    @Test func anOrdinaryCancelCarriesNoReason() throws {
        let fields = try #require(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(ControlAskResult(result: .cancelled))) as? [String: Any])

        #expect(fields["reason"] == nil)
    }

    @Test func aResultFromAServerWithoutTheReasonDecodes() throws {
        let result = try JSONDecoder().decode(ControlAskResult.self, from: Data(#"{"result":"cancelled"}"#.utf8))

        #expect(result == ControlAskResult(result: .cancelled))
    }

    @Test func inputAnswerCarriesTheDraftTextAndCancelEscapesWithoutIt() {
        let ask = PendingAsk(id: "a", title: "Name", buttons: formButtons,
                             form: .input(AskInputForm(mode: .multiline, value: "draft")), cancelID: "cancel")
        var draft = AskDraft(form: ask.form)
        #expect(draft.text == "draft")
        draft.text = "  line one\nline two  "
        #expect(ask.answer(buttonAt: 0, draft: draft)
            == ControlAskResult(result: .answered, id: "ok", label: "OK", index: 0, text: "  line one\nline two  "))
        #expect(ask.answer(buttonAt: 1, draft: draft) == ControlAskResult(result: .escaped))
        #expect(ask.answer(buttonAt: 2, draft: draft) == nil)
    }

    @Test func choiceAnswerListsCheckedIDsInCallerOrder() {
        let form = AskForm.choices(AskChoiceForm(choices: choices("a", "b", "c"), multiple: true, checked: ["c"]))
        let ask = PendingAsk(id: "a", title: "Pick", buttons: formButtons, form: form, cancelID: "cancel")
        var draft = AskDraft(form: form)
        draft.toggle(at: 0)
        #expect(draft.selected == ["a", "c"])
        #expect(ask.answer(buttonAt: 0, draft: draft)?.selected == ["a", "c"])
        #expect(ask.answer(buttonAt: 0, draft: draft)?.text == nil)
    }

    @Test func answerWithoutADraftUsesTheFormsInitialValues() {
        let ask = PendingAsk(id: "a", title: "Pick", buttons: formButtons,
                             form: .choices(AskChoiceForm(choices: choices("a", "b"))))
        #expect(ask.answer(buttonAt: 0, draft: nil)?.selected == ["a"])
    }

    @Test func cancelRoleAppliesWithoutAForm() {
        let ask = PendingAsk(id: "a", title: "Go?", buttons: formButtons, cancelID: "cancel")
        #expect(ask.answer(buttonAt: 1, draft: nil) == ControlAskResult(result: .escaped))
        #expect(ask.answer(buttonAt: 0, draft: nil) == ControlAskResult(result: .answered, id: "ok", label: "OK", index: 0))
    }

    @Test func radioDraftStartsOnTheFirstItemAndPicksExactlyOne() {
        var draft = AskDraft(form: .choices(AskChoiceForm(choices: choices("a", "b", "c"))))
        #expect(draft.selected == ["a"])
        #expect(draft.cursor == 0)
        draft.moveCursor(by: 2)
        draft.toggleCursor()
        #expect(draft.selected == ["c"])
        draft.toggleCursor()
        #expect(draft.selected == ["c"])
    }

    @Test func draftCursorStartsOnTheFirstCheckedItemAndStopsAtTheEnds() {
        var draft = AskDraft(form: .choices(AskChoiceForm(choices: choices("a", "b", "c"), multiple: true, checked: ["c", "b"])))
        #expect(draft.cursor == 1)
        draft.moveCursor(by: -5)
        #expect(draft.cursor == 0)
        draft.moveCursor(by: 9)
        #expect(draft.cursor == 2)
    }

    @Test func checkboxDraftTogglesAndMayEndEmpty() {
        var draft = AskDraft(form: .choices(AskChoiceForm(choices: choices("a", "b"), multiple: true, checked: ["b"])))
        draft.toggle(at: 1)
        #expect(draft.selected.isEmpty)
        draft.toggle(at: 7)
        #expect(draft.selected.isEmpty)
        #expect(draft.cursor == 1)
    }

    @Test(arguments: [false, true])
    func typingSelectsTheOtherRowAndBlankTextDisablesIt(multiple: Bool) {
        var draft = AskDraft(form: otherForm(multiple: multiple))
        #expect(!draft.otherEnabled)
        draft.text = " "
        #expect(!draft.otherEnabled && !draft.otherSelected && draft.otherText == nil)
        draft.text = " x"
        #expect(draft.otherEnabled && draft.otherSelected && draft.otherText == " x")
        draft.text = "  "
        #expect(!draft.otherEnabled && !draft.otherSelected && draft.otherText == nil)
        #expect(draft.text == "  ")
    }

    @Test func radioOtherRestoresThePickItTookOverFrom() {
        var draft = AskDraft(form: otherForm(multiple: false, checked: ["b"]))
        draft.text = "x"
        #expect(draft.selected.isEmpty && draft.otherSelected)
        draft.text = "xyz"
        draft.text = ""
        #expect(draft.selected == ["b"] && !draft.otherSelected)
    }

    @Test func radioPickElsewhereKeepsOtherTextAndClearingItKeepsThatPick() {
        var draft = AskDraft(form: otherForm(multiple: false, checked: ["b"]))
        draft.text = "x"
        draft.toggle(at: 2)
        #expect(draft.selected == ["c"] && !draft.otherSelected && draft.text == "x" && draft.otherEnabled)
        draft.text = ""
        #expect(draft.selected == ["c"])
        draft.text = "y"
        #expect(draft.selected.isEmpty && draft.otherSelected)
        draft.text = ""
        #expect(draft.selected == ["c"])
    }

    @Test func radioOtherWithoutAnInitialPickFallsBackToTheFirstItem() {
        var draft = AskDraft(form: otherForm(multiple: false))
        draft.toggle(at: 3)
        #expect(!draft.otherSelected)
        draft.text = "x"
        draft.text = ""
        #expect(draft.selected == ["a"])
    }

    @Test func radioOtherMarkerPicksAnEnabledRowAndIsANoOpOncePicked() {
        var draft = AskDraft(form: otherForm(multiple: false, checked: ["b"]))
        draft.text = "x"
        draft.toggle(at: 0)
        draft.toggle(at: 3)
        #expect(draft.otherSelected && draft.selected.isEmpty)
        draft.toggle(at: 3)
        #expect(draft.otherSelected && draft.selected.isEmpty)
        draft.text = ""
        #expect(draft.selected == ["a"])
    }

    @Test func checkboxOtherMarkerTogglesWhileEnabledAndKeepsTheText() {
        var draft = AskDraft(form: otherForm(multiple: true, checked: ["a"]))
        draft.toggle(at: 3)
        #expect(!draft.otherSelected)
        draft.text = "x"
        draft.toggle(at: 3)
        #expect(!draft.otherSelected && draft.otherEnabled && draft.text == "x" && draft.otherText == nil)
        #expect(draft.selected == ["a"])
        draft.text = "xy"
        #expect(draft.otherSelected && draft.otherText == "xy")
    }

    @Test func cursorReachesTheOtherRowAfterFiftyItemsAndClampsThere() {
        let items = (1...ControlAskChoice.maxChoices).map { ControlAskChoice(id: "i\($0)", label: "I\($0)") }
        var draft = AskDraft(form: .choices(AskChoiceForm(choices: items, multiple: true, other: "Other")))
        draft.moveCursor(by: 100)
        #expect(draft.cursor == ControlAskChoice.maxChoices && draft.cursorOnOther)
        draft.moveCursor(by: 1)
        #expect(draft.cursor == ControlAskChoice.maxChoices)
        draft.moveCursor(by: -1)
        #expect(!draft.cursorOnOther)
        var plain = AskDraft(form: .choices(AskChoiceForm(choices: choices("a", "b"))))
        plain.moveCursor(by: 5)
        #expect(plain.cursor == 1 && !plain.cursorOnOther)
    }

    @Test(arguments: [false, true])
    func otherAnswerReturnsRawTextOnlyWhileSelected(multiple: Bool) {
        let form = AskForm.choices(AskChoiceForm(choices: choices("a", "b", "other"), multiple: multiple, checked: ["other"],
                                                 other: "Something else"))
        let ask = PendingAsk(id: "a", title: "Pick", buttons: formButtons, form: form, cancelID: "cancel")
        var draft = AskDraft(form: form)
        draft.text = "  mine  "
        let answered = ask.answer(buttonAt: 0, draft: draft)
        #expect(answered?.text == "  mine  ")
        #expect(answered?.selected == (multiple ? ["other"] : []))
        #expect(ask.answer(buttonAt: 1, draft: draft) == ControlAskResult(result: .escaped))
        draft.toggle(at: 0)
        #expect(ask.answer(buttonAt: 0, draft: draft)?.text == (multiple ? "  mine  " : nil))
        if multiple { draft.toggle(at: 3) }
        #expect(ask.answer(buttonAt: 0, draft: draft)?.text == nil)
    }

    @Test(arguments: [
        OtherAnswer(false, [], " mine ", true), OtherAnswer(false, ["a"], nil, true), OtherAnswer(true, ["a", "c"], " mine ", true),
        OtherAnswer(true, [], nil, true), OtherAnswer(false, ["a"], "mine", false), OtherAnswer(false, [], nil, false),
        OtherAnswer(true, ["a"], "  ", false), OtherAnswer(true, [], "a\u{1}b", false), OtherAnswer(true, [], "a\tb", false),
        OtherAnswer(true, [], String(repeating: "x", count: AskInputForm.maxTextBytes + 1), false),
    ])
    func validatedOtherAnswerFollowsTheFormsShape(answer: OtherAnswer) {
        let ask = PendingAsk(id: "a", title: "Pick", buttons: formButtons, form: otherForm(multiple: answer.multiple), cancelID: "cancel")
        let result = ask.validatedAnswer(buttonID: "ok", text: answer.text, selected: answer.selected)
        #expect((result != nil) == answer.accepted)
        if answer.accepted {
            #expect(result == ControlAskResult(result: .answered, id: "ok", label: "OK", index: 0, text: answer.text, selected: answer.selected))
        }
    }

    @Test(arguments: [false, true])
    func retypingTheSameTextReselectsTheRow(multiple: Bool) {
        var draft = AskDraft(form: otherForm(multiple: multiple))
        draft.text = "x"
        draft.toggle(at: multiple ? 3 : 0)
        #expect(!draft.otherSelected)
        draft.text = "x"
        #expect(draft.otherSelected && draft.otherText == "x")
    }

    @Test func validatedChoiceAnswerRefusesTextWithoutAnOtherRow() {
        let ask = PendingAsk(id: "a", title: "Pick", buttons: formButtons,
                             form: .choices(AskChoiceForm(choices: choices("a", "b"), multiple: true)), cancelID: "cancel")
        #expect(ask.validatedAnswer(buttonID: "ok", text: "x", selected: ["a"]) == nil)
        #expect(ask.validatedAnswer(buttonID: "cancel", text: nil, selected: nil) == ControlAskResult(result: .escaped))
        #expect(ask.validatedAnswer(buttonID: "cancel", text: "x", selected: nil) == nil)
    }

    @Test(arguments: [(AskInputForm.maxTextBytes, AskInputForm.maxTextBytes), (AskInputForm.maxTextBytes + 1, AskInputForm.maxTextBytes)])
    func draftTextIsClampedToTheByteCap(length: Int, expected: Int) {
        var draft = AskDraft(form: .input(AskInputForm(mode: .line)))
        draft.text = String(repeating: "x", count: length)
        #expect(draft.text.utf8.count == expected)
    }

    @Test func clampingNeverSplitsAMultibyteCharacter() {
        let text = String(repeating: "é", count: AskInputForm.maxTextBytes / 2) + "é"
        let clamped = AskInputForm.clamped(text)
        #expect(clamped.utf8.count == AskInputForm.maxTextBytes)
        #expect(clamped.allSatisfy { $0 == "é" })
    }

    @Test(arguments: [
        ("plain é \"q\"", ControlAskInputMode.line, false), ("a\nb\tc", .multiline, false),
        ("a\nb", .line, true), ("a\tb", .line, true), ("a\u{1}b", .multiline, true),
        ("a\rb", .multiline, true), ("a\u{7f}", .multiline, true), ("a\u{1b}[31m", .line, true),
    ])
    func controlCharactersAreForbiddenExceptNewlineAndTabInMultiline(text: String, mode: ControlAskInputMode, forbidden: Bool) {
        #expect(AskInputForm.hasForbiddenControls(text, mode: mode) == forbidden)
    }

    @Test(arguments: ControlAskStyle.allCases)
    func slotOwnersKeepTheDraftUntilResolutionAndIgnoreStaleIDs(style: ControlAskStyle) {
        let session = Session(initialCwd: "/tmp")
        let controller = PickController()
        let ask = PendingAsk(id: "a", title: "Name", buttons: formButtons, style: style,
                             form: .input(AskInputForm(mode: .line, value: "x")), cancelID: "cancel")
        let draft: () -> AskDraft? = { style == .terminal ? session.askDraft : controller.askDraft }
        let update: (String, String) -> Void = { id, text in
            if style == .terminal { session.updateAskDraft(id: id) { $0.text = text } } else {
                controller.updateAskDraft(id: id) { $0.text = text }
            }
        }
        #expect(style == .terminal ? session.openAsk(ask) : controller.openAsk(ask))
        update("a", "typed")
        update("stale", "lost")
        #expect(draft()?.text == "typed")
        if style == .terminal { session.answerAsk(id: "a", buttonAt: 0) } else { controller.answerAsk(id: "a", buttonAt: 0) }
        #expect(draft() == nil)
        #expect(style == .terminal ? session.askPending == nil : controller.pendingAsk == nil)
    }

    @Test func releasingASessionAskDropsItsDraft() {
        let session = Session(initialCwd: "/tmp")
        #expect(session.openAsk(PendingAsk(id: "a", title: "Name", buttons: formButtons, form: .input(AskInputForm(mode: .line)))))
        session.releaseAsk()
        #expect(session.askDraft == nil)
    }

    @Test func aPlainResultEncodesWithoutFormFields() throws {
        let data = try JSONEncoder().encode(ControlAskResult(result: .answered, id: "ok", label: "OK", index: 0))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["result", "id", "label", "index"])
    }

    @Test func formResultsRoundTrip() throws {
        for result in [ControlAskResult(result: .answered, id: "ok", label: "OK", index: 0, text: "a \"q\"\n\\"),
                       ControlAskResult(result: .answered, id: "ok", label: "OK", index: 0, selected: [])] {
            let decoded = try JSONDecoder().decode(ControlAskResult.self, from: JSONEncoder().encode(result))
            #expect(decoded == result)
        }
    }

    @Test func anchoringKeepsTheFormAndCancelRole() {
        let form = AskForm.choices(AskChoiceForm(choices: choices("a")))
        let ask = PendingAsk(id: "a", title: "Pick", buttons: formButtons, form: form, cancelID: "cancel")
        let anchored = ask.anchored(at: AskAnchor(sessionID: UUID()))
        #expect(anchored.form == form)
        #expect(anchored.cancelID == "cancel")
        #expect(anchored.anchor != nil)
    }

    private var formButtons: [ControlAskButton] {
        [ControlAskButton(id: "ok", label: "OK"), ControlAskButton(id: "cancel", label: "Cancel")]
    }

    private func choices(_ ids: String...) -> [ControlAskChoice] {
        ids.map { ControlAskChoice(id: $0, label: $0.uppercased()) }
    }

    private func otherForm(multiple: Bool, checked: [String] = []) -> AskForm {
        .choices(AskChoiceForm(choices: choices("a", "b", "c"), multiple: multiple, checked: checked, other: "Something else"))
    }

    private func buttons(count: Int) -> [ControlAskButton] {
        (0..<count).map { ControlAskButton(id: "button-\($0)", label: "Button \($0)") }
    }
}

struct OtherAnswer: Sendable {
    let multiple: Bool
    let selected: [String]
    let text: String?
    let accepted: Bool

    init(_ multiple: Bool, _ selected: [String], _ text: String?, _ accepted: Bool) {
        self.multiple = multiple
        self.selected = selected
        self.text = text
        self.accepted = accepted
    }
}
