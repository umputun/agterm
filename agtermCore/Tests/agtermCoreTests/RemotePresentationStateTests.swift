import Foundation
import Testing
@testable import agtermCore

@MainActor
struct RemotePresentationStateTests {
    static let remoteLeft = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let remoteRight = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!

    private func attached(version: Int? = 1, split: Bool = true, store: AppStore? = nil) throws -> (AppStore, Session) {
        let store = store ?? makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", remoteHost: "buildbox"))
        if split { store.toggleSplit(session.id) }
        var daemons = [session.paneIdentity: ZmxSupport.daemonName(for: Self.remoteLeft)]
        if let local = session.splitPaneIdentity { daemons[local] = ZmxSupport.daemonName(for: Self.remoteRight) }
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: daemons,
                                       presentationVersion: version), forSession: session.id)
        return (store, session)
    }

    private final class Flag: @unchecked Sendable {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    private func status(_ status: AgentStatus, pane: PresentationPane?) -> PresentationStatus {
        PresentationStatus(status: status, blink: true, color: "#ff8800", shape: .star, pane: pane, changedAt: nil)
    }

    @Test func aDaemonNameDecodesBackToThePaneIdentityItWasBuiltFrom() {
        let identity = UUID()

        #expect(ZmxSupport.paneIdentity(fromDaemonName: ZmxSupport.daemonName(for: identity)) == identity)
        #expect(ZmxSupport.paneIdentity(fromDaemonName: "agterm-notes") == nil)
    }

    @Test func theBindingMapsEachRemotePaneToItsLocalOne() throws {
        let (_, session) = try attached()

        let binding = try #require(session.remotePresentation?.binding)
        #expect(binding.remoteSessionID == "s1")
        #expect(binding.localPane(forRemote: Self.remoteLeft) == session.paneIdentity)
        #expect(binding.localPane(forRemote: Self.remoteRight) == session.splitPaneIdentity)
        #expect(binding.localPane(forRemote: UUID()) == nil)
    }

    @Test(arguments: [(Int?.some(1), RemotePresentationConnection.connecting), (nil, .unsupported)])
    func anOriginWithoutTheCapabilityReadsUnsupported(_ version: Int?, _ expected: RemotePresentationConnection) throws {
        let (_, session) = try attached(version: version)

        #expect(session.remotePresentation?.connection == expected)
    }

    @Test(arguments: [RemotePresentationConnection.connected, .unsupported])
    func aRowWithAStreamUpOrNoneToHaveShowsNoNotice(_ connection: RemotePresentationConnection) {
        #expect(connection.rowNotice(host: "buildbox") == nil)
    }

    @Test(arguments: [RemotePresentationConnection.connecting, .failed("exit 255")])
    func aRowWhoseStreamIsNotUpNamesTheHost(_ connection: RemotePresentationConnection) throws {
        let notice = try #require(connection.rowNotice(host: "buildbox"))

        #expect(notice.contains("buildbox"))
    }

    @Test func aFailedStreamsNoticeCarriesTheReasonAndTheManualRecovery() throws {
        let notice = try #require(RemotePresentationConnection.failed("exit 255").rowNotice(host: "buildbox"))

        #expect(notice.contains("exit 255"))
        #expect(notice.contains("reattach"))
    }

    @Test func aMirroredStatusLandsOnTheMappedLocalPaneWithItsGlyphOverrides() throws {
        let (store, session) = try attached()

        store.applyRemoteStatus(status(.blocked, pane: .identity(Self.remoteRight)), forSession: session.id)

        #expect(session.agentIndicator == AgentIndicator(status: .blocked, blink: true, color: "#ff8800",
                                                         shape: .star, statusPane: .right))
    }

    @Test func aMirroredClearFromAnotherPaneIsAppliedWhereTheControlPathWouldRefuseIt() throws {
        let (store, session) = try attached()
        store.applyRemoteStatus(status(.blocked, pane: .identity(Self.remoteLeft)), forSession: session.id)
        #expect(store.applyControlStatus(AgentIndicator(status: .idle, statusPane: .right), forSession: session.id)
                == .refused(owner: .left))

        store.applyRemoteStatus(status(.active, pane: .identity(Self.remoteRight)), forSession: session.id)
        #expect(session.agentIndicator.status == .active)
        store.applyRemoteStatus(nil, forSession: session.id)

        #expect(session.agentIndicator.status == .idle)
    }

    @Test(arguments: [PresentationPane.identity(UUID()), .scratch])
    func anOriginPaneWithNoCounterpartHereGetsNoLocalOwner(_ pane: PresentationPane) throws {
        let (store, session) = try attached()

        store.applyRemoteStatus(status(.blocked, pane: pane), forSession: session.id)

        #expect(session.agentIndicator.status == .blocked)
        #expect(session.agentIndicator.statusPane == nil)
        #expect(session.remotePresentation?.allowsKeystrokeStatusClear == false)
    }

    @Test func aPaneClosedHereSinceTheAttachNoLongerOwnsAMirroredStatus() throws {
        let (store, session) = try attached()
        store.closeSplit(session.id)

        store.applyRemoteStatus(status(.blocked, pane: .identity(Self.remoteRight)), forSession: session.id)

        #expect(session.agentIndicator.statusPane == nil)
        #expect(session.remotePresentation?.allowsKeystrokeStatusClear == false)
    }

    @Test func aMappedPaneMayClearItsOwnMirroredStatus() throws {
        let (store, session) = try attached()

        store.applyRemoteStatus(status(.blocked, pane: .identity(Self.remoteLeft)), forSession: session.id)

        #expect(session.remotePresentation?.allowsKeystrokeStatusClear == true)
    }

    @Test func theOriginsTimestampOrdersTheRowNotTheArrivalTime() throws {
        let (store, session) = try attached()
        let mirrored = PresentationStatus(status: .blocked, blink: false, color: nil, shape: nil, pane: nil,
                                          changedAt: 1_700_000_000)

        store.applyRemoteStatus(mirrored, forSession: session.id)

        #expect(session.statusChangedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func aLocalWriteOfTheVerySameValueTakesTheStatusAwayFromTheBridge() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        store.applyRemoteStatus(status(.blocked, pane: nil), forSession: session.id)
        let same = session.agentIndicator

        store.setAgentIndicator(same, forSession: session.id)
        store.setRemoteConnection(.connecting, forSession: session.id)

        #expect(session.agentIndicator == same)
    }

    // every reconnect brings a snapshot, which overwrote a status set on this Mac's row
    @Test(arguments: [PresentationStatus?.none, PresentationStatus(status: .completed, blink: false, color: nil,
                                                                   shape: nil, pane: nil, changedAt: nil)])
    func aSnapshotLeavesAStatusSetLocallyAlone(_ origin: PresentationStatus?) throws {
        let (store, session) = try attached()
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)

        store.applyRemoteSnapshotStatus(origin, forSession: session.id)

        #expect(session.agentIndicator.status == .blocked)
        #expect(session.remotePresentation?.statusBridged == false)
    }

    @Test func aStatusClearedLocallyGivesTheRowBackToTheNextSnapshot() throws {
        let (store, session) = try attached()
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(), forSession: session.id)

        store.applyRemoteSnapshotStatus(status(.completed, pane: nil), forSession: session.id)

        #expect(session.agentIndicator.status == .completed)
        #expect(session.remotePresentation?.statusBridged == true)
    }

    @Test func aSnapshotReplacesAStatusTheBridgeSet() throws {
        let (store, session) = try attached()
        store.applyRemoteStatus(status(.blocked, pane: nil), forSession: session.id)

        store.applyRemoteSnapshotStatus(nil, forSession: session.id)

        #expect(session.agentIndicator.status == .idle)
    }

    @Test func aSnapshotFillsAnIdleRow() throws {
        let (store, session) = try attached()

        store.applyRemoteSnapshotStatus(status(.blocked, pane: nil), forSession: session.id)

        #expect(session.agentIndicator.status == .blocked)
        #expect(session.remotePresentation?.statusBridged == true)
    }

    @Test func aDeltaStillReplacesAStatusSetLocally() throws {
        let (store, session) = try attached()
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)

        store.applyRemoteStatus(status(.completed, pane: nil), forSession: session.id)

        #expect(session.agentIndicator.status == .completed)
    }

    @Test func aMirroredContextShowsOnARowWithNoneOfItsOwn() throws {
        let (store, session) = try attached()

        store.applyRemoteContext("PR #517", forSession: session.id)

        #expect(session.effectiveContext == "PR #517")
        #expect(session.context == nil)
    }

    @Test func aContextSetHereWinsOverTheMirroredOne() throws {
        let (store, session) = try attached()
        store.applyRemoteContext("origin", forSession: session.id)

        store.setContext("local", forSession: session.id)

        #expect(session.effectiveContext == "local")
    }

    @Test func clearingTheLocalContextRevealsWhatTheOriginSentMeanwhile() throws {
        let (store, session) = try attached()
        store.applyRemoteContext("first", forSession: session.id)
        store.setContext("local", forSession: session.id)
        store.applyRemoteContext("second", forSession: session.id)

        store.setContext(nil, forSession: session.id)

        #expect(session.effectiveContext == "second")
    }

    @Test func anOriginClearUnderALocalContextIsRemembered() throws {
        let (store, session) = try attached()
        store.applyRemoteContext("origin", forSession: session.id)
        store.setContext("local", forSession: session.id)
        store.applyRemoteContext(nil, forSession: session.id)

        store.setContext(nil, forSession: session.id)

        #expect(session.effectiveContext == nil)
    }

    @Test func settingTheSameTextAsTheMirrorStillMakesALocalOverride() throws {
        let (store, session) = try attached()
        store.applyRemoteContext("same", forSession: session.id)

        #expect(store.setContext("same", forSession: session.id) == true)
        store.applyRemoteContext("changed", forSession: session.id)

        #expect(session.effectiveContext == "same")
    }

    @Test func losingTheStreamWithdrawsTheMirroredContextAndKeepsALocalOne() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        store.applyRemoteContext("origin", forSession: session.id)
        store.setContext("local", forSession: session.id)

        store.setRemoteConnection(.connecting, forSession: session.id)
        store.setContext(nil, forSession: session.id)

        #expect(session.effectiveContext == nil)
    }

    @Test func aMirroredContextIsIgnoredOnALocalSession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))

        store.applyRemoteContext("origin", forSession: session.id)

        #expect(session.effectiveContext == nil)
    }

    @Test func theTreeReportsTheEffectiveContext() throws {
        let (store, session) = try attached()
        store.applyRemoteContext("origin", forSession: session.id)

        let node = try #require(store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })

        #expect(node.context == "origin")
    }

    @Test func aMirroredContextInvalidatesAnObserverOfTheEffectiveValue() throws {
        let (store, session) = try attached()
        let invalidated = Flag()
        withObservationTracking { _ = session.effectiveContext } onChange: { invalidated.set() }

        store.applyRemoteContext("origin", forSession: session.id)

        #expect(invalidated.isSet)
    }

    @Test func contextEventsFollowOnlyTheEffectiveValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var events: [ControlEventKind] = []
        let store = AppStore(persistence: PersistenceStore(directory: directory),
                             controlEventSink: { events.append($0.kind) }, paneFinalizer: nil)
        let (_, session) = try attached(store: store)
        store.setRemoteConnection(.connected, forSession: session.id)
        events.removeAll()

        store.applyRemoteContext("origin", forSession: session.id)
        #expect(events == [.treeChanged])
        events.removeAll()
        store.applyRemoteContext("origin", forSession: session.id)
        store.setContext("origin", forSession: session.id)
        store.applyRemoteContext("new origin", forSession: session.id)
        #expect(events.isEmpty)

        store.setContext(nil, forSession: session.id)
        #expect(events == [.treeChanged])
        events.removeAll()
        store.setRemoteConnection(.failed("offline"), forSession: session.id)
        #expect(events == [.treeChanged])
        #expect(session.effectiveContext == nil)
    }

    @Test func mirroredContextUpdatesAndDisconnectNeverSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(persistence: PersistenceStore(directory: directory), paneFinalizer: nil)
        let (_, session) = try attached(store: store)
        store.setRemoteConnection(.connected, forSession: session.id)
        let snapshot = directory.appendingPathComponent("workspaces.json")
        try FileManager.default.removeItem(at: snapshot)

        store.applyRemoteContext("origin", forSession: session.id)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        store.setRemoteConnection(.connecting, forSession: session.id)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
    }

    @Test func losingTheStreamClearsTheMirroredStatus() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        store.applyRemoteStatus(status(.blocked, pane: nil), forSession: session.id)

        store.setRemoteConnection(.failed("connection reset"), forSession: session.id)

        #expect(session.agentIndicator.status == .idle)
        #expect(session.remotePresentation?.connection == .failed("connection reset"))
    }

    @Test func losingTheStreamLeavesAStatusSetLocallyAlone() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        store.applyRemoteStatus(status(.active, pane: nil), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: session.id)

        store.setRemoteConnection(.connecting, forSession: session.id)

        #expect(session.agentIndicator.status == .completed)
    }

    @Test func losingTheStreamClosesOnlyAHudTheBridgeOpened() throws {
        let (store, session) = try attached()
        let size = HudPanelSize(widthPercent: 30, heightPercent: 8)
        store.setRemoteConnection(.connected, forSession: session.id)
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "mirrored"), file: "/tmp/agterm-x",
                      size: size)
        store.markHudBridged(forSession: session.id)
        #expect(session.remotePresentation?.hudBridged == true)

        store.setRemoteConnection(.connecting, forSession: session.id)
        #expect(!session.hudActive)

        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "local"), file: "/tmp/agterm-x",
                      size: size)
        store.setRemoteConnection(.connected, forSession: session.id)
        store.setRemoteConnection(.connecting, forSession: session.id)
        #expect(session.hudActive, "a panel the viewer's own program opened is not the bridge's to close")
    }

    @Test func aLocalReplacementTakesTheHudAwayFromTheBridge() throws {
        let (store, session) = try attached()
        let size = HudPanelSize(widthPercent: 30, heightPercent: 8)
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "mirrored"), file: "/tmp/agterm-x",
                      size: size)
        store.markHudBridged(forSession: session.id)

        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "local"), file: "/tmp/agterm-x",
                      size: size)

        #expect(session.remotePresentation?.hudBridged == false)
        #expect(!store.closeBridgedHud(forSession: session.id))
        #expect(session.hudActive)
    }

    @Test func aBridgedHudNeverClosesAProgramOverlay() throws {
        let (store, session) = try attached()
        #expect(store.openOverlay(session.id, command: "htop"))

        #expect(!store.closeBridgedHud(forSession: session.id))

        #expect(session.programOverlayActive)
    }

    @Test func aRemoteSessionAndItsBindingNeverReachASnapshot() throws {
        let (store, session) = try attached()

        #expect(!store.snapshot().workspaces.flatMap(\.sessions).contains { $0.id == session.id })
    }

    private func handedOver(pane: PresentationPane? = nil) -> PresentationAsk {
        PresentationAsk(PendingAsk(id: UUID().uuidString, title: "deploy?",
                                   buttons: [ControlAskButton(id: "yes", label: "Yes"), ControlAskButton(id: "no", label: "No")]),
                        pane: pane, owner: 4)
    }

    @Test func aHandedOverAskIsShownOverTheMappedPaneAsAReplica() throws {
        let (store, session) = try attached()
        let ask = handedOver(pane: .identity(Self.remoteRight))

        #expect(store.presentReplicaAsk(ask, forSession: session.id) { _ in })

        #expect(session.askPending?.id == ask.id)
        #expect(session.askPaneIdentity == session.splitPaneIdentity)
        #expect(session.askReplica)
        #expect(store.controlTree().workspaces[0].sessions[0].ask == ControlSessionAsk(id: ask.id, pane: "right", replica: true))
    }

    @Test func anOccupiedSlotRefusesTheReplica() throws {
        let (store, session) = try attached()
        session.openAsk(PendingAsk(id: "local", title: "local", buttons: [ControlAskButton(id: "ok", label: "OK")]))

        #expect(!store.presentReplicaAsk(handedOver(), forSession: session.id) { _ in })
        #expect(session.askPending?.id == "local")
    }

    @Test(arguments: [false, true])
    func aPaneNotShownHereRefusesTheReplica(_ unmapped: Bool) throws {
        let (store, session) = try attached()
        if !unmapped { session.isSplit = false }

        let pane = PresentationPane.identity(unmapped ? UUID() : Self.remoteRight)
        #expect(!store.presentReplicaAsk(handedOver(pane: pane), forSession: session.id) { _ in })
        #expect(session.askPending == nil)
    }

    @Test func anAnswerSendsTheButtonIdAlone() throws {
        let (store, session) = try attached()
        let ask = handedOver()
        var sent: [PresentationFrame.Body] = []
        store.presentReplicaAsk(ask, forSession: session.id) { sent.append($0) }

        session.resolveAsk(id: ask.id, ControlAskResult(result: .answered, id: "no", label: "No", index: 1))

        #expect(sent == [.askResolve(PresentationAskAnswer(id: ask.id, owner: 4, button: "no"))])
        #expect(session.askPending == nil)
    }

    @Test func aDismissalWithEscSendsNoButton() throws {
        let (store, session) = try attached()
        let ask = handedOver()
        var sent: [PresentationFrame.Body] = []
        store.presentReplicaAsk(ask, forSession: session.id) { sent.append($0) }

        session.resolveAsk(id: ask.id, ControlAskResult(result: .escaped))

        #expect(sent == [.askResolve(PresentationAskAnswer(id: ask.id, owner: 4, button: nil))])
    }

    @Test func aCancelHereRefusesTheAskSoTheOriginTakesItBack() throws {
        let (store, session) = try attached()
        let ask = handedOver()
        var sent: [PresentationFrame.Body] = []
        store.presentReplicaAsk(ask, forSession: session.id) { sent.append($0) }

        session.cancelPendingAsk()

        #expect(sent == [.askRejected(PresentationAskRef(id: ask.id, owner: 4))])
    }

    @Test func theOriginsDismissalTakesTheReplicaDownWithoutAnswering() throws {
        let (store, session) = try attached()
        let ask = handedOver()
        var sent: [PresentationFrame.Body] = []
        store.presentReplicaAsk(ask, forSession: session.id) { sent.append($0) }

        store.dismissReplicaAsk(PresentationAskRef(id: ask.id, owner: 4), forSession: session.id)

        #expect(session.askPending == nil)
        #expect(!session.askReplica)
        #expect(sent.isEmpty)
    }

    @Test func aDismissalNamingAnotherAskLeavesTheReplica() throws {
        let (store, session) = try attached()
        let ask = handedOver()
        store.presentReplicaAsk(ask, forSession: session.id) { _ in }

        store.dismissReplicaAsk(PresentationAskRef(id: "other", owner: 4), forSession: session.id)

        #expect(session.askPending?.id == ask.id)
    }

    @Test func losingTheStreamTakesTheReplicaDownWithoutAnswering() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        let ask = handedOver()
        var sent: [PresentationFrame.Body] = []
        store.presentReplicaAsk(ask, forSession: session.id) { sent.append($0) }

        store.setRemoteConnection(.failed("exit 255"), forSession: session.id)

        #expect(session.askPending == nil)
        #expect(sent.isEmpty)
    }

    @Test func losingTheStreamLeavesAnAskOfThisMacsOwn() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        session.openAsk(PendingAsk(id: "local", title: "local", buttons: [ControlAskButton(id: "ok", label: "OK")]))

        store.setRemoteConnection(.failed("exit 255"), forSession: session.id)

        #expect(session.askPending?.id == "local")
    }

    @Test func aSessionWithNoBindingIgnoresMirroredState() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))

        store.applyRemoteStatus(status(.blocked, pane: nil), forSession: session.id)

        #expect(session.agentIndicator.status == .idle)
    }

    static let runJob = "ssh -tt buildbox run-job j1"

    private func overlay(pane: PresentationPane? = nil, size: Int? = nil, wait: Bool = false,
                         follow: Bool = false) -> PresentationOverlay {
        PresentationOverlay(job: "j1", pane: pane, sizePercent: size, backgroundColor: "#102030", follow: follow, wait: wait)
    }

    private final class Closed { var jobs: [String] = [] }

    @discardableResult
    private func show(_ overlay: PresentationOverlay, in store: AppStore, _ session: Session, closed: Closed = Closed()) -> Bool {
        store.presentReplicaOverlay(overlay, command: Self.runJob, forSession: session.id) { closed.jobs.append($0) }
    }

    @Test func aHandedOverOverlayRunsTheJobsCommandInTheSessionWideSlot() throws {
        let (store, session) = try attached()

        #expect(show(overlay(size: 60, wait: true), in: store, session))

        #expect(session.overlayActive)
        #expect(session.overlayCommand == Self.runJob)
        #expect(session.overlayWait)
        #expect(session.overlayBackgroundColor == "#102030")
        #expect(session.overlayReplica?.job == "j1")
        let node = store.controlTree().workspaces[0].sessions[0]
        #expect(node.overlay)
        #expect(node.overlaySizePercent == 60)
        #expect(node.paneOverlays == nil)
    }

    @Test func aPaneOverlayCoversTheMappedPaneOnly() throws {
        let (store, session) = try attached()

        #expect(show(overlay(pane: .identity(Self.remoteRight)), in: store, session))

        #expect(session.paneOverlay(.right)?.command == Self.runJob)
        #expect(session.paneOverlay(.right)?.replica?.job == "j1")
        #expect(!session.overlayActive)
        let node = store.controlTree().workspaces[0].sessions[0]
        #expect(!node.overlay)
        #expect(node.paneOverlays == ["right"])
    }

    @Test func anOverlayWithFollowSelectsItsSession() throws {
        let (store, session) = try attached()
        let other = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp"))
        store.selectSession(other.id)

        show(overlay(follow: true), in: store, session)

        #expect(store.selectedSessionID == session.id)
    }

    @Test func anOccupiedSlotRefusesTheOverlay() throws {
        let (store, session) = try attached()
        store.openOverlay(session.id, command: "top")

        #expect(!show(overlay(), in: store, session))
        #expect(session.overlayCommand == "top")
    }

    @Test(arguments: [false, true])
    func aPaneNotShownHereRefusesTheOverlay(_ unmapped: Bool) throws {
        let (store, session) = try attached()
        if !unmapped { session.isSplit = false }

        #expect(!show(overlay(pane: .identity(unmapped ? UUID() : Self.remoteRight)), in: store, session))
        #expect(session.paneOverlay(.right) == nil)
    }

    @Test func closingTheSurfaceHereTellsTheOrigin() throws {
        let (store, session) = try attached()
        let closed = Closed()
        show(overlay(), in: store, session, closed: closed)

        store.closeOverlay(session.id)

        #expect(closed.jobs == ["j1"])
        #expect(session.overlayReplica == nil)
    }

    @Test func aPaneOverlayClosedHereOrWithItsPaneTellsTheOrigin() throws {
        let (store, session) = try attached()
        let closed = Closed()
        show(overlay(pane: .identity(Self.remoteRight)), in: store, session, closed: closed)
        store.closePaneOverlay(session.id, pane: .right)
        show(overlay(pane: .identity(Self.remoteRight)), in: store, session, closed: closed)

        store.closeSplit(session.id)

        #expect(closed.jobs == ["j1", "j1"])
    }

    @Test func aLocalOverlayClosingTellsTheOriginNothing() throws {
        let (store, session) = try attached()
        let closed = Closed()
        show(overlay(pane: .identity(Self.remoteRight)), in: store, session, closed: closed)
        store.openOverlay(session.id, command: "top")

        store.closeOverlay(session.id)

        #expect(closed.jobs.isEmpty)
    }

    @Test func theOriginsCloseTakesTheOverlayDown() throws {
        let (store, session) = try attached()
        let closed = Closed()
        show(overlay(pane: .identity(Self.remoteRight)), in: store, session, closed: closed)

        store.closeReplicaOverlay("j1", forSession: session.id)

        #expect(session.paneOverlay(.right) == nil)
        #expect(closed.jobs == ["j1"])
    }

    @Test func theOriginsResizeAppliesToItsOwnJobOnly() throws {
        let (store, session) = try attached()
        show(overlay(size: 60), in: store, session)

        store.resizeReplicaOverlay(PresentationOverlayChange(job: "other", sizePercent: 20), forSession: session.id)
        store.resizeReplicaOverlay(PresentationOverlayChange(job: "j1", sizePercent: 40), forSession: session.id)

        #expect(session.overlaySizePercent == 40)
    }

    @Test func aHeldSurfaceStaysUpWhileItsStreamIs() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        show(overlay(wait: true), in: store, session)

        store.replicaOverlayHeld(forSession: session.id, pane: nil)

        #expect(session.overlayActive)
        #expect(session.overlayReplica?.ended == true)
    }

    @Test func losingTheStreamClosesAHeldSurfaceAtOnce() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        show(overlay(wait: true), in: store, session)
        store.replicaOverlayHeld(forSession: session.id, pane: nil)

        store.setRemoteConnection(.failed("exit 255"), forSession: session.id)

        #expect(!session.overlayActive)
    }

    @Test(arguments: [false, true])
    func aRunningOverlayOutlivesTheStreamAndClosesWhenItsJobEnds(_ reconnected: Bool) throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        show(overlay(pane: .identity(Self.remoteRight), wait: true), in: store, session)

        store.setRemoteConnection(.failed("exit 255"), forSession: session.id)
        #expect(session.paneOverlay(.right) != nil)
        if reconnected { store.setRemoteConnection(.connected, forSession: session.id) }
        store.replicaOverlayHeld(forSession: session.id, pane: .right)

        #expect(session.paneOverlay(.right) == nil)
    }

    // regression: a replica held during a soft close's undo grace came back dead, its held exit never seen
    @Test(arguments: [false, true])
    func softClosingTheRowClosesItsReplicasAndKeepsLocalOverlays(_ paneReplica: Bool) throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        let closed = Closed()
        if paneReplica {
            show(overlay(pane: .identity(Self.remoteRight), wait: true), in: store, session, closed: closed)
            store.openOverlay(session.id, command: "top")
        } else {
            show(overlay(wait: true), in: store, session, closed: closed)
            store.openPaneOverlay(session.id, pane: .right, command: "top")
        }

        #expect(store.softCloseSession(session.id))
        #expect(store.undoPendingClose())

        #expect(closed.jobs == ["j1"])
        #expect(session.overlayReplicas.isEmpty)
        #expect(paneReplica ? session.overlayCommand == "top" : session.paneOverlay(.right)?.command == "top")
    }

    @Test func aRunningOverlayCutOffFromItsStreamStillTakesTheOriginsClose() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connected, forSession: session.id)
        show(overlay(), in: store, session)
        store.setRemoteConnection(.failed("exit 255"), forSession: session.id)
        store.setRemoteConnection(.connected, forSession: session.id)

        store.closeReplicaOverlay("j1", forSession: session.id)

        #expect(!session.overlayActive)
    }
}
