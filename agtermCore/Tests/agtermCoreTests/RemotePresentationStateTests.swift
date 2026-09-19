import Foundation
import Testing
@testable import agtermCore

@MainActor
struct RemotePresentationStateTests {
    static let remoteLeft = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    static let remoteRight = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!

    private func attached(version: Int? = 1, split: Bool = true) throws -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", remoteHost: "buildbox"))
        if split { store.toggleSplit(session.id) }
        var daemons = [session.paneIdentity: ZmxSupport.daemonName(for: Self.remoteLeft)]
        if let local = session.splitPaneIdentity { daemons[local] = ZmxSupport.daemonName(for: Self.remoteRight) }
        store.bindRemote(RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: daemons,
                                       presentationVersion: version), forSession: session.id)
        return (store, session)
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

    @Test func aSessionWithNoBindingIgnoresMirroredState() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))

        store.applyRemoteStatus(status(.blocked, pane: nil), forSession: session.id)

        #expect(session.agentIndicator.status == .idle)
    }
}
