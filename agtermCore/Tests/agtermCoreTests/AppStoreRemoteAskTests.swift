import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreRemoteAskTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }
    }

    static let buttons = [ControlAskButton(id: "yes", label: "Yes"), ControlAskButton(id: "no", label: "No")]
    static let window = UUID()

    let store = makeStore()
    let hub = PresentationHub(staleTimeout: 30)
    let presenter = Sink()
    let mirror = Sink()

    private func origin(presented: Bool = true, split: Bool = false,
                        kinds: [String] = []) throws -> (Session, PresentationHub.SubscriberID?) {
        store.presentationHub = hub
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        if split { store.toggleSplit(session.id) }
        setLead(.follower, pane: session.paneIdentity)
        if let pane = session.splitPaneIdentity { setLead(.follower, pane: pane) }
        guard presented else { return (session, nil) }
        let hello = PresentationHello(version: 1, kinds: kinds, mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) {
            PresentationSnapshot(status: nil, hud: nil)
        }
        try hub.subscribe(session: session.id, hello: hello, sink: mirror) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        return (session, id)
    }

    private func ask(style: ControlAskStyle = .terminal) -> PendingAsk {
        PendingAsk(id: UUID().uuidString, title: "deploy?", buttons: Self.buttons, style: style)
    }

    private func owner(of session: Session) -> Int { hub.presenterGeneration(session: session.id) }

    private func setLead(_ role: ZmxLeadRole?, pane: UUID) {
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: pane)
        if let role, let notice = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(role.rawValue):1") {
            _ = ZmxLeadBook.shared.apply(notice, pane: pane)
        }
    }

    @Test(arguments: [nil, .unowned, .leader, .follower] as [ZmxLeadRole?],
          [nil, .unowned, .leader, .follower] as [ZmxLeadRole?])
    func aSessionAskRequiresEveryPaneToFollow(left: ZmxLeadRole?, right: ZmxLeadRole?) throws {
        let (session, _) = try origin(split: true)
        setLead(left, pane: session.paneIdentity)
        setLead(right, pane: try #require(session.splitPaneIdentity))
        let remote = left == .follower && right == .follower

        let result = store.presentAskRemotely(ask(), in: session, paneIdentity: nil, window: Self.window)

        #expect(result == (remote ? true : nil))
        #expect(session.askPresentedRemotely == remote)
        if !remote {
            #expect(session.askPending == nil)
            #expect(!presenter.bodies.contains { if case .askRequest = $0 { true } else { false } })
        }
    }

    @Test(arguments: [nil, .unowned, .leader, .follower] as [ZmxLeadRole?], OverlayPane.allCases)
    func aPaneAskUsesOnlyItsOwnLead(role: ZmxLeadRole?, pane: OverlayPane) throws {
        let (session, _) = try origin(split: true)
        let right = try #require(session.splitPaneIdentity)
        setLead(pane == .left ? role : .leader, pane: session.paneIdentity)
        setLead(pane == .right ? role : .leader, pane: right)
        let identity = pane == .left ? session.paneIdentity : right

        let result = store.presentAskRemotely(ask(), in: session, paneIdentity: identity, window: Self.window)

        #expect(result == (role == .follower ? true : nil))
        #expect(session.askPresentedRemotely == (role == .follower))
    }

    @Test func askRoutingFollowsSwappedPaneIdentities() throws {
        let (session, _) = try origin(split: true)
        session.surface = SpySurface(paneToken: "primary")
        session.splitSurface = SpySurface(paneToken: "split")
        setLead(.leader, pane: session.paneIdentity)
        #expect(store.swapPanes(session.id) == nil)

        #expect(store.presentAskRemotely(ask(), in: session, paneIdentity: session.splitPaneIdentity, window: Self.window) == nil)
        #expect(store.presentAskRemotely(ask(), in: session, paneIdentity: session.paneIdentity, window: Self.window) == true)
    }

    @Test func aRemoteAskStillCancelsAfterTakingTheLeadHere() throws {
        let (session, _) = try origin()
        let pending = ask()
        #expect(store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window) == true)
        setLead(.leader, pane: session.paneIdentity)

        session.cancelAsk(id: pending.id)

        #expect(presenter.bodies.last == .askDismiss(PresentationAskRef(id: pending.id, owner: owner(of: session))))
        #expect(AskRegistry.shared.result(for: pending.id)?.result.result == .cancelled)
    }

    @Test func losingAPresenterLeavesALocalAskAlone() throws {
        let (session, id) = try origin()
        setLead(.leader, pane: session.paneIdentity)
        let pending = ask()
        #expect(store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window) == nil)
        #expect(session.openAsk(pending))
        hub.onPresenterLost = { [store] in _ = store.takeBackRemoteAsk(forSession: $0) }

        hub.unsubscribe(try #require(id))

        #expect(session.askPending?.id == pending.id)
        #expect(!session.askPresentedRemotely)
    }

    @Test func aSessionAskGoesToThePresenterAloneAndIsNotDrawnHere() throws {
        let (session, _) = try origin()
        let pending = ask()

        #expect(store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window) == true)

        #expect(presenter.bodies.last == .askRequest(PresentationAsk(pending, pane: nil, owner: owner(of: session))))
        #expect(!mirror.bodies.contains { if case .askRequest = $0 { true } else { false } })
        #expect(session.askPending?.id == pending.id)
        #expect(session.askPresentedRemotely)
    }

    @Test func aPaneAskCarriesTheOriginsPaneIdentity() throws {
        let (session, _) = try origin(split: true)
        let pending = ask()
        let pane = try #require(session.splitPaneIdentity)

        store.presentAskRemotely(pending, in: session, paneIdentity: pane, window: Self.window)

        #expect(presenter.bodies.last == .askRequest(PresentationAsk(pending, pane: .identity(pane), owner: owner(of: session))))
    }

    @Test func withoutAPresenterTheCallerOpensTheAskItself() throws {
        let (session, _) = try origin(presented: false)

        #expect(store.presentAskRemotely(ask(), in: session, paneIdentity: nil, window: Self.window) == nil)
        #expect(session.askPending == nil)
    }

    @Test func aSecondAskWhileOneIsPresentedIsRefused() throws {
        let (session, _) = try origin()
        store.presentAskRemotely(ask(), in: session, paneIdentity: nil, window: Self.window)

        #expect(store.presentAskRemotely(ask(), in: session, paneIdentity: nil, window: Self.window) == false)
    }

    @Test func anAnswerTakesItsLabelAndIndexFromTheStoredButtons() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "no"),
                                       forSession: session.id))

        #expect(AskRegistry.shared.result(for: pending.id)?.result
            == ControlAskResult(result: .answered, id: "no", label: "No", index: 1))
    }

    @Test func anAnswerNamingAButtonTheAskDoesNotHaveIsRefused() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(!store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "maybe"),
                                        forSession: session.id))
        #expect(session.askPending?.id == pending.id)
    }

    @Test func anAnswerUnderAnotherOwnerIsRefused() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(!store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session) + 1, button: "yes"),
                                        forSession: session.id))
        #expect(session.askPending?.id == pending.id)
    }

    @Test(arguments: [AskForm.input(AskInputForm(mode: .line)), .choices(AskChoiceForm(choices: [ControlAskChoice(id: "a", label: "A")])), nil])
    func aFormOrCancelRoleAskStaysHereForAPresenterWithoutTheCapability(form: AskForm?) throws {
        let (session, _) = try origin()
        let pending = PendingAsk(id: UUID().uuidString, title: "t", buttons: Self.buttons, form: form, cancelID: "no")

        #expect(store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window) == nil)
        #expect(session.askPending == nil)
        #expect(!presenter.bodies.contains { if case .askRequest = $0 { true } else { false } })
    }

    @Test func aFormAskGoesToAPresenterListingTheCapability() throws {
        let (session, _) = try origin(kinds: [PresentationHub.askFormKind])
        let pending = PendingAsk(id: UUID().uuidString, title: "t", buttons: Self.buttons,
                                 form: .input(AskInputForm(mode: .multiline, value: "v")), cancelID: "no")

        #expect(store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window) == true)
        let request = PresentationAsk(pending, pane: nil, owner: owner(of: session))
        #expect(presenter.bodies.last == .askRequest(request))
        #expect(request.form == pending.form)
        #expect(request.cancelID == "no")
    }

    @Test func aFormAskWhoseFrameIsTooLargeStaysHere() throws {
        let (session, _) = try origin(kinds: [PresentationHub.askFormKind])
        let pending = PendingAsk(id: UUID().uuidString, title: "t", message: String(repeating: "m", count: PresentationCodec.maxFrameBytes),
                                 buttons: Self.buttons, form: .input(AskInputForm(mode: .line)))

        #expect(store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window) == nil)
    }

    @Test func anInputAskStaysHereWhenItsLongestButtonAndTheReservedTextCannotFitAnAnswer() throws {
        let (session, _) = try origin(kinds: [PresentationHub.askFormKind])
        let long = ControlAskButton(id: String(repeating: "b", count: 200 * 1024), label: "Long")
        let input = PendingAsk(id: UUID().uuidString, title: "t", buttons: [long], form: .input(AskInputForm(mode: .line)))
        let list = PendingAsk(id: UUID().uuidString, title: "t", buttons: [long],
                              form: .choices(AskChoiceForm(choices: [ControlAskChoice(id: "a", label: "A")])))

        #expect(PresentationAsk(input, pane: nil, owner: 1).fitsFrames() == false)
        #expect(PresentationAsk(list, pane: nil, owner: 1).fitsFrames())
        #expect(store.presentAskRemotely(input, in: session, paneIdentity: nil, window: Self.window) == nil)
    }

    @Test(arguments: [false, true])
    func anOtherRowAskStaysHereUnlessThePresenterListsBothCapabilities(formOnly: Bool) throws {
        let (session, _) = try origin(kinds: [formOnly ? PresentationHub.askFormKind : PresentationHub.askOtherKind])
        let pending = PendingAsk(id: UUID().uuidString, title: "t", buttons: Self.buttons, form: .choices(remoteRadioOther), cancelID: "no")

        #expect(store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window) == nil)
        #expect(session.askPending == nil)
    }

    @Test func anOtherRowAskGoesToAPresenterListingBothCapabilities() throws {
        let (session, _) = try origin(kinds: [PresentationHub.askFormKind, PresentationHub.askOtherKind])
        let pending = PendingAsk(id: UUID().uuidString, title: "t", buttons: Self.buttons, form: .choices(remoteRadioOther), cancelID: "no")

        #expect(store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window) == true)
        #expect(presenter.bodies.last == .askRequest(PresentationAsk(pending, pane: nil, owner: owner(of: session))))
    }

    @Test func aCheckboxOtherAskReservesEveryIDPlusTheWidestText() throws {
        let otherAnswer = PresentationAskAnswer(id: "a", owner: 1, button: "ok", text: String(repeating: "\"", count: AskInputForm.maxTextBytes),
                                                selected: [])
        let base = try PresentationCodec.encode(PresentationFrame(gen: .max, rev: .max, body: .askResolve(otherAnswer))).count
        let room = PresentationCodec.maxFrameBytes - base
        func ask(idLength: Int, multiple: Bool) -> PresentationAsk {
            let items = (0..<2).map { ControlAskChoice(id: "\($0)" + String(repeating: "i", count: idLength), label: "L") }
            return PresentationAsk(PendingAsk(id: "a", title: "t", buttons: [ControlAskButton(id: "ok", label: "OK")],
                                              form: .choices(AskChoiceForm(choices: items, multiple: multiple, other: "Other"))),
                                   pane: nil, owner: 1)
        }
        #expect(ask(idLength: room / 2, multiple: true).fitsFrames() == false)
        #expect(ask(idLength: room / 2, multiple: false).fitsFrames())
        #expect(ask(idLength: room / 8, multiple: true).fitsFrames())
    }

    @Test func slashesInAButtonIDCountAsTheCodecWritesThem() {
        let slashes = ControlAskButton(id: String(repeating: "/", count: 90 * 1024), label: "Slashes")
        let letters = ControlAskButton(id: String(repeating: "b", count: 150 * 1024), label: "Letters")
        let ask = PendingAsk(id: "a", title: "t", buttons: [slashes, letters], form: .input(AskInputForm(mode: .line)))

        #expect(PresentationAsk(ask, pane: nil, owner: 1).fitsFrames() == false)
    }

    @Test func anAnswerThatFitsOnlyWithShortCountersIsRefused() throws {
        let probe = PresentationAskAnswer(id: "a", owner: 1, button: "", text: String(repeating: "\"", count: AskInputForm.maxTextBytes))
        let base = try PresentationCodec.encode(PresentationFrame(gen: 0, rev: 0, body: .askResolve(probe))).count
        let slack = PresentationCodec.maxFrameBytes - base - 1
        let id = String(repeating: "b", count: slack - 5)
        let ask = PendingAsk(id: "a", title: "t", buttons: [ControlAskButton(id: id, label: "B")],
                             form: .input(AskInputForm(mode: .line)))
        let answer = PresentationAskAnswer(id: "a", owner: 1, button: id, text: String(repeating: "\"", count: AskInputForm.maxTextBytes))

        #expect((try? PresentationCodec.encode(PresentationFrame(gen: 0, rev: 0, body: .askResolve(answer)))) != nil)
        #expect(PresentationAsk(ask, pane: nil, owner: 1).fitsFrames() == false)
    }

    @Test(arguments: [
        (RemoteFormAnswer(.input(AskInputForm(mode: .multiline)), "yes", "a \"q\"\nb\tc", nil),
         ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0, text: "a \"q\"\nb\tc")),
        (RemoteFormAnswer(.choices(remoteCheckboxes), "yes", nil, ["a", "b"]),
         ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0, selected: ["a", "b"])),
        (RemoteFormAnswer(.choices(remoteCheckboxes), "yes", nil, []),
         ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0, selected: [])),
        (RemoteFormAnswer(.input(AskInputForm(mode: .line)), "no", nil, nil), ControlAskResult(result: .escaped)),
        (RemoteFormAnswer(.choices(remoteRadioOther), "yes", " mine ", []),
         ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0, text: " mine ", selected: [])),
        (RemoteFormAnswer(.choices(remoteCheckboxesOther), "yes", "mine", ["b"]),
         ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0, text: "mine", selected: ["b"])),
    ])
    func aFormAnswerIsAppliedWithItsPayload(answer: RemoteFormAnswer, expected: ControlAskResult) throws {
        let (session, _) = try origin(kinds: [PresentationHub.askFormKind, PresentationHub.askOtherKind])
        let pending = PendingAsk(id: UUID().uuidString, title: "t", buttons: Self.buttons, form: answer.form, cancelID: "no")
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(store.resolveRemoteAsk(answer.frame(id: pending.id, owner: owner(of: session)), forSession: session.id))
        #expect(AskRegistry.shared.result(for: pending.id)?.result == expected)
    }

    @Test(arguments: [
        RemoteFormAnswer(.input(AskInputForm(mode: .line)), "yes", nil, ["a"]),
        RemoteFormAnswer(.input(AskInputForm(mode: .line)), "yes", nil, nil),
        RemoteFormAnswer(.input(AskInputForm(mode: .line)), "yes", String(repeating: "x", count: AskInputForm.maxTextBytes + 1), nil),
        RemoteFormAnswer(.input(AskInputForm(mode: .line)), "yes", "a\u{1}b", nil),
        RemoteFormAnswer(.input(AskInputForm(mode: .line)), "yes", "a\tb", nil),
        RemoteFormAnswer(.input(AskInputForm(mode: .multiline)), "yes", "a\u{7f}\nb", nil),
        RemoteFormAnswer(.input(AskInputForm(mode: .line)), "no", "typed", nil),
        RemoteFormAnswer(.input(AskInputForm(mode: .line)), nil, "typed", nil),
        RemoteFormAnswer(.choices(remoteRadio), "yes", nil, ["c"]),
        RemoteFormAnswer(.choices(remoteRadio), "yes", nil, []),
        RemoteFormAnswer(.choices(remoteRadio), "yes", nil, ["a", "b"]),
        RemoteFormAnswer(.choices(remoteRadio), "yes", "text", ["a"]),
        RemoteFormAnswer(.choices(remoteCheckboxes), "yes", nil, ["b", "a"]),
        RemoteFormAnswer(.choices(remoteCheckboxes), "yes", nil, ["a", "a"]),
        RemoteFormAnswer(.choices(remoteCheckboxes), "yes", nil, nil),
        RemoteFormAnswer(.choices(remoteCheckboxes), "yes", "mine", ["a"]),
        RemoteFormAnswer(.choices(remoteRadioOther), "yes", "mine", ["a"]),
        RemoteFormAnswer(.choices(remoteRadioOther), "yes", "  ", []),
        RemoteFormAnswer(.choices(remoteCheckboxesOther), "yes", "a\tb", ["a"]),
    ])
    func aFormAnswerWithAPayloadItsFormWouldNotProduceIsRefused(answer: RemoteFormAnswer) throws {
        let (session, _) = try origin(kinds: [PresentationHub.askFormKind, PresentationHub.askOtherKind])
        let pending = PendingAsk(id: UUID().uuidString, title: "t", buttons: Self.buttons, form: answer.form, cancelID: "no")
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(!store.resolveRemoteAsk(answer.frame(id: pending.id, owner: owner(of: session)), forSession: session.id))
        #expect(session.askPending?.id == pending.id)
    }

    @Test func aPlainAskAnswerCarryingAPayloadIsRefused() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(!store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "yes", text: "x"),
                                        forSession: session.id))
        #expect(session.askPending?.id == pending.id)
    }

    @Test func aDismissalOnTheViewerCompletesEscaped() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: nil),
                               forSession: session.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result == ControlAskResult(result: .escaped))
    }

    @Test func theFirstResultWins() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)
        let answer = PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "yes")
        store.resolveRemoteAsk(answer, forSession: session.id)

        #expect(!store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "no"),
                                        forSession: session.id))
        #expect(AskRegistry.shared.result(for: pending.id)?.result.id == "yes")
    }

    @Test func aCancelHereCompletesCancelledAndTellsThePresenterToDismiss() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        session.cancelAsk(id: pending.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result == ControlAskResult(result: .cancelled))
        #expect(presenter.bodies.last == .askDismiss(PresentationAskRef(id: pending.id, owner: owner(of: session))))
    }

    @Test func aSoftCloseCancelsTheAskAndTellsThePresenter() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        store.softCloseSession(session.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result.result == .cancelled)
        #expect(presenter.bodies.contains(.askDismiss(PresentationAskRef(id: pending.id, owner: 1))))
    }

    @Test func closingTheCoveredPaneCancelsTheAskAndTellsThePresenter() throws {
        let (session, _) = try origin(split: true)
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: session.splitPaneIdentity, window: Self.window)
        let frameCount = presenter.frames.count

        store.closeSplit(session.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result.result == .cancelled)
        #expect(Array(presenter.bodies.dropFirst(frameCount)) == [
            .askDismiss(PresentationAskRef(id: pending.id, owner: 1)),
            .layout(PresentationLayout(panes: [session.paneIdentity], primary: session.paneIdentity, shown: false)),
        ])
    }

    @Test func aTakenBackTerminalAskIsDrawnHereAndALateAnswerIsRefused() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)
        let stale = PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "yes")

        #expect(store.takeBackRemoteAsk(forSession: session.id) == nil)

        #expect(session.askPending?.id == pending.id)
        #expect(!session.askPresentedRemotely)
        #expect(!store.resolveRemoteAsk(stale, forSession: session.id))
    }

    @Test func aTakenBackGuiAskIsLeftForTheHostToPlace() throws {
        let (session, _) = try origin()
        let pending = ask(style: .gui)
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(store.takeBackRemoteAsk(forSession: session.id)?.id == pending.id)
        #expect(session.askPresentedRemotely)
    }

    @Test func aHandbackThatCannotBeShownEndsCancelledWithTheReason() throws {
        let (session, _) = try origin()
        let pending = ask(style: .gui)
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        store.failHandback(forSession: session.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result
            == ControlAskResult(result: .cancelled, reason: ControlAskResult.presentationLost))
        #expect(session.askPending == nil)
    }

    @Test func aRefusalIsHonouredOnlyForTheAskBeingPresented() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(store.isPresentingRemotely(PresentationAskRef(id: pending.id, owner: owner(of: session)), forSession: session.id))
        #expect(!store.isPresentingRemotely(PresentationAskRef(id: "other", owner: owner(of: session)), forSession: session.id))
        #expect(!store.isPresentingRemotely(PresentationAskRef(id: pending.id, owner: 99), forSession: session.id))
    }

    @Test func losingThePresenterReportsTheSessionToTheHost() throws {
        var lost: [UUID] = []
        hub.onPresenterLost = { lost.append($0) }
        let (session, id) = try origin()

        hub.unsubscribe(try #require(id))

        #expect(lost == [session.id])
    }

    @Test func onlyTheCurrentPresentersAskFramesReachTheHost() throws {
        var received: [PresentationFrame.Body] = []
        hub.onPresenterFrame = { _, body in received.append(body) }
        let (_, id) = try origin()
        let presenterID = try #require(id)
        let mirrorID = PresentationHub.SubscriberID(generation: 2)
        let rejected = PresentationFrame.Body.askRejected(PresentationAskRef(id: "a", owner: 1))

        hub.receive(PresentationFrame(gen: 2, rev: 1, body: rejected), from: mirrorID)
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 1, body: rejected), from: presenterID)

        #expect(received == [rejected])
    }
}

private let remoteRadio = AskChoiceForm(choices: [ControlAskChoice(id: "a", label: "A"), ControlAskChoice(id: "b", label: "B")])
private let remoteRadioOther = AskChoiceForm(choices: [ControlAskChoice(id: "a", label: "A"), ControlAskChoice(id: "b", label: "B")],
                                             other: "Other")
private let remoteCheckboxesOther = AskChoiceForm(choices: [ControlAskChoice(id: "a", label: "A"), ControlAskChoice(id: "b", label: "B")],
                                                  multiple: true, other: "Other")
private let remoteCheckboxes = AskChoiceForm(choices: [ControlAskChoice(id: "a", label: "A"), ControlAskChoice(id: "b", label: "B")],
                                             multiple: true)

struct RemoteFormAnswer: Sendable {
    let form: AskForm
    let button: String?
    let text: String?
    let selected: [String]?

    init(_ form: AskForm, _ button: String?, _ text: String?, _ selected: [String]?) {
        self.form = form
        self.button = button
        self.text = text
        self.selected = selected
    }

    func frame(id: String, owner: Int) -> PresentationAskAnswer {
        PresentationAskAnswer(id: id, owner: owner, button: button, text: text, selected: selected)
    }
}
