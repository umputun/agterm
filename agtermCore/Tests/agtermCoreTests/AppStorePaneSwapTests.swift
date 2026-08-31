import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStorePaneSwapTests {
    private final class RigidSurface: TerminalSurface {
        var isRealized = true
        var paneToken = "rigid"
        func teardown() {}
        func promoteToPrimaryPane() {}
    }

    private struct Fixture {
        let store: AppStore
        let session: Session
        let primary: SpySurface
        let split: SpySurface
        let leftOverlay: SpySurface
        let rightOverlay: SpySurface
    }

    private struct State: Equatable {
        let surface: ObjectIdentifier?
        let splitSurface: ObjectIdentifier?
        let paneIdentity: UUID
        let splitPaneIdentity: UUID?
        let currentCwd: String?
        let splitCwd: String?
        let initialSplitCwd: String?
        let oscTitle: String?
        let splitTitle: String?
        let foregroundCommand: [String]?
        let splitForegroundCommand: [String]?
        let restoreCommand: String?
        let splitRestoreCommand: String?
        let pendingRestoreCommand: String?
        let pendingSplitRestoreCommand: String?
        let pendingForegroundCommand: [String]?
        let pendingSplitForegroundCommand: [String]?
        let initialCommand: String?
        let splitInitialCommand: String?
        let commandWait: Bool
        let splitCommandWait: Bool
        let leftOverlay: PaneOverlay?
        let rightOverlay: PaneOverlay?
        let leftOverlaySurface: ObjectIdentifier?
        let rightOverlaySurface: ObjectIdentifier?
        let leftOverlayExitCode: Int?
        let rightOverlayExitCode: Int?
        let indicator: AgentIndicator
        let statusChangedAt: Date?
        let isSplit: Bool
        let hasSplit: Bool
        let splitAxis: SplitAxis
        let splitRatio: Double?
        let splitFocused: Bool

        @MainActor init(_ session: Session) {
            surface = session.surface.map { ObjectIdentifier($0) }
            splitSurface = session.splitSurface.map { ObjectIdentifier($0) }
            paneIdentity = session.paneIdentity
            splitPaneIdentity = session.splitPaneIdentity
            currentCwd = session.currentCwd
            splitCwd = session.splitCwd
            initialSplitCwd = session.initialSplitCwd
            oscTitle = session.oscTitle
            splitTitle = session.splitTitle
            foregroundCommand = session.foregroundCommand
            splitForegroundCommand = session.splitForegroundCommand
            restoreCommand = session.restoreCommand
            splitRestoreCommand = session.splitRestoreCommand
            pendingRestoreCommand = session.pendingRestoreCommand
            pendingSplitRestoreCommand = session.pendingSplitRestoreCommand
            pendingForegroundCommand = session.pendingForegroundCommand
            pendingSplitForegroundCommand = session.pendingSplitForegroundCommand
            initialCommand = session.initialCommand
            splitInitialCommand = session.splitInitialCommand
            commandWait = session.commandWait
            splitCommandWait = session.splitCommandWait
            leftOverlay = session.leftOverlay
            rightOverlay = session.rightOverlay
            leftOverlaySurface = session.leftOverlaySurface.map { ObjectIdentifier($0) }
            rightOverlaySurface = session.rightOverlaySurface.map { ObjectIdentifier($0) }
            leftOverlayExitCode = session.leftOverlayExitCode
            rightOverlayExitCode = session.rightOverlayExitCode
            indicator = session.agentIndicator
            statusChangedAt = session.statusChangedAt
            isSplit = session.isSplit
            hasSplit = session.hasSplit
            splitAxis = session.splitAxis
            splitRatio = session.splitRatio
            splitFocused = session.splitFocused
        }
    }

    private func makeSeededSession() -> Fixture {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/initial-left")!
        let primary = SpySurface(paneToken: "primary")
        let split = SpySurface(paneToken: "split")
        let leftOverlay = SpySurface(paneToken: "overlay-left")
        let rightOverlay = SpySurface(paneToken: "overlay-right")
        session.surface = primary
        session.splitSurface = split
        session.paneIdentity = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        session.splitPaneIdentity = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        session.isSplit = false
        session.hasSplit = true
        session.splitAxis = .topBottom
        session.splitRatio = 0.3
        session.splitFocused = false
        session.currentCwd = "/live-left"
        session.splitCwd = "/live-right"
        session.initialSplitCwd = "/live-right"
        session.oscTitle = "left-title"
        session.splitTitle = "right-title"
        session.foregroundCommand = ["left", "foreground"]
        session.splitForegroundCommand = ["right", "foreground"]
        session.restoreCommand = nil
        session.splitRestoreCommand = "right restore"
        session.pendingRestoreCommand = "left pending restore"
        session.pendingSplitRestoreCommand = nil
        session.pendingForegroundCommand = ["left", "pending"]
        session.pendingSplitForegroundCommand = ["right", "pending"]
        session.initialCommand = "left command"
        session.splitInitialCommand = "right command"
        session.commandWait = false
        session.splitCommandWait = true
        session.setPaneOverlay(PaneOverlay(command: "left overlay", cwd: "/left"), pane: .left)
        session.setPaneOverlay(PaneOverlay(command: "right overlay", cwd: "/right"), pane: .right)
        session.setPaneOverlaySurface(leftOverlay, pane: .left)
        session.setPaneOverlaySurface(rightOverlay, pane: .right)
        session.setPaneOverlayExitCode(7, pane: .left)
        session.setPaneOverlayExitCode(9, pane: .right)
        session.agentIndicator = AgentIndicator(status: .blocked, statusPane: .left)
        session.statusChangedAt = Date(timeIntervalSince1970: 123)
        return Fixture(store: store, session: session, primary: primary, split: split,
                       leftOverlay: leftOverlay, rightOverlay: rightOverlay)
    }

    @Test func swapExchangesEveryPaneFieldAndKeepsLayout() {
        let fixture = makeSeededSession()
        let session = fixture.session

        #expect(fixture.store.swapPanes(session.id) == nil)

        #expect(session.surface === fixture.split)
        #expect(session.splitSurface === fixture.primary)
        #expect(session.paneIdentity == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(session.splitPaneIdentity == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(session.currentCwd == "/live-right")
        #expect(session.splitCwd == "/live-left")
        #expect(session.initialSplitCwd == "/live-left")
        #expect(session.oscTitle == "right-title")
        #expect(session.splitTitle == "left-title")
        #expect(session.foregroundCommand == ["right", "foreground"])
        #expect(session.splitForegroundCommand == ["left", "foreground"])
        #expect(session.restoreCommand == "right restore")
        #expect(session.splitRestoreCommand == nil)
        #expect(session.pendingRestoreCommand == nil)
        #expect(session.pendingSplitRestoreCommand == "left pending restore")
        #expect(session.pendingForegroundCommand == ["right", "pending"])
        #expect(session.pendingSplitForegroundCommand == ["left", "pending"])
        #expect(session.initialCommand == "right command")
        #expect(session.splitInitialCommand == "left command")
        #expect(session.commandWait)
        #expect(!session.splitCommandWait)
        #expect(session.leftOverlay?.command == "right overlay")
        #expect(session.rightOverlay?.command == "left overlay")
        #expect(session.leftOverlaySurface === fixture.rightOverlay)
        #expect(session.rightOverlaySurface === fixture.leftOverlay)
        #expect(session.leftOverlayExitCode == 9)
        #expect(session.rightOverlayExitCode == 7)
        #expect(session.agentIndicator.statusPane == .right)
        #expect(session.statusChangedAt == Date(timeIntervalSince1970: 123))
        #expect(!session.isSplit)
        #expect(session.hasSplit)
        #expect(session.splitAxis == .topBottom)
        #expect(session.splitRatio == 0.3)
        #expect(session.splitFocused)
    }

    @Test func swappedPaneIdentitiesStayPairedThroughHiddenSplitRestore() throws {
        let fixture = makeSeededSession()

        #expect(fixture.store.swapPanes(fixture.session.id) == nil)
        let persisted = fixture.store.snapshot().workspaces[0].sessions[0]
        let restoredStore = makeStore()
        restoredStore.restore(from: Snapshot(workspaces: [
            WorkspaceSnapshot(id: UUID(), name: "work", sessions: [persisted]),
        ]))
        let restored = try #require(restoredStore.workspaces[0].sessions.first)

        #expect(!restored.isSplit)
        #expect(restored.hasSplit)
        #expect(restored.paneIdentity == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(restored.splitPaneIdentity == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(restored.initialCommand == "right command")
        #expect(restored.commandWait)
        #expect(restored.splitInitialCommand == "left command")
        #expect(!restored.splitCommandWait)
    }

    @Test func swapAssignsEachSurfaceItsNewRole() {
        let fixture = makeSeededSession()

        #expect(fixture.store.swapPanes(fixture.session.id) == nil)
        #expect(fixture.primary.assignedRoles == [.split])
        #expect(fixture.split.assignedRoles == [.primary])
    }

    @Test func swapUsesCwdFallbacks() {
        let fixture = makeSeededSession()
        fixture.session.currentCwd = nil
        fixture.session.splitCwd = nil
        fixture.session.initialSplitCwd = "/seed-right"

        #expect(fixture.store.swapPanes(fixture.session.id) == nil)
        #expect(fixture.session.currentCwd == "/seed-right")
        #expect(fixture.session.splitCwd == "/initial-left")
        #expect(fixture.session.initialSplitCwd == "/initial-left")
    }

    @Test func swappingTwiceRestoresPaneStateIncludingNilPin() {
        let fixture = makeSeededSession()
        let before = State(fixture.session)
        let snapshotBefore = fixture.store.snapshot()

        #expect(fixture.store.swapPanes(fixture.session.id) == nil)
        #expect(fixture.store.swapPanes(fixture.session.id) == nil)
        #expect(State(fixture.session) == before)
        #expect(fixture.store.snapshot() == snapshotBefore)
    }

    @Test func closeSplitAfterSwapDropsOnlyTheDepartedCreationIdentity() {
        let fixture = makeSeededSession()

        #expect(fixture.store.swapPanes(fixture.session.id) == nil)
        fixture.store.closeSplit(fixture.session.id)

        #expect(fixture.session.initialCommand == "right command")
        #expect(fixture.session.commandWait)
        #expect(fixture.session.splitInitialCommand == nil)
        #expect(!fixture.session.splitCommandWait)
        #expect(!fixture.session.hasSplit)
    }

    @Test func primaryExitAfterSwapPromotesTheSurvivingCreationIdentity() {
        let fixture = makeSeededSession()

        #expect(fixture.store.swapPanes(fixture.session.id) == nil)
        fixture.store.closePrimaryPane(fixture.session.id)

        #expect(fixture.session.surface === fixture.primary)
        #expect(fixture.session.initialCommand == "left command")
        #expect(!fixture.session.commandWait)
        #expect(fixture.session.splitInitialCommand == nil)
        #expect(!fixture.session.splitCommandWait)
        #expect(!fixture.session.hasSplit)
    }

    @Test func swapRetagsEveryStatusOwnerWithoutChangingStatusTime() {
        let cases: [(AgentStatus, StatusPane?, StatusPane?)] = [
            (.blocked, nil, .right), (.completed, .left, .right), (.active, .right, .left),
            (.blocked, .scratch, .scratch), (.idle, nil, nil),
        ]
        for (status, before, expected) in cases {
            let fixture = makeSeededSession()
            fixture.session.agentIndicator = AgentIndicator(status: status, statusPane: before)
            let changedAt = Date(timeIntervalSince1970: 456)
            fixture.session.statusChangedAt = changedAt

            #expect(fixture.store.swapPanes(fixture.session.id) == nil)
            #expect(fixture.session.agentIndicator.status == status)
            #expect(fixture.session.agentIndicator.statusPane == expected)
            #expect(fixture.session.statusChangedAt == changedAt)
        }
    }

    @Test(arguments: [true, false])
    func swapRefusesMissingSlotWithoutMutation(missingPrimary: Bool) {
        let fixture = makeSeededSession()
        if missingPrimary { fixture.session.surface = nil } else { fixture.session.splitSurface = nil }
        let before = State(fixture.session)

        #expect(fixture.store.swapPanes(fixture.session.id) == .slotNotRealized)
        #expect(State(fixture.session) == before)
    }

    @Test func swapRefusesUnknownOrSplitlessSessionWithoutMutation() {
        let store = makeStore()
        let before = store.snapshot()
        #expect(store.swapPanes(UUID()) == .noSession)
        #expect(store.snapshot() == before)

        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/a")!
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        let sessionBefore = State(session)
        #expect(store.swapPanes(session.id) == .noSplit)
        #expect(State(session) == sessionBefore)
    }

    @Test(arguments: [true, false])
    func swapRefusesRigidSurfaceWithoutMutation(rigidPrimary: Bool) {
        let fixture = makeSeededSession()
        if rigidPrimary {
            fixture.session.surface = RigidSurface()
        } else {
            fixture.session.splitSurface = RigidSurface()
        }
        let before = State(fixture.session)

        #expect(fixture.store.swapPanes(fixture.session.id) == .roleNotMutable)
        #expect(State(fixture.session) == before)
    }
}
