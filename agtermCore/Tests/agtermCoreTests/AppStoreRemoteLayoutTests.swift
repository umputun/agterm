import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreRemoteLayoutTests {
    let originA = UUID()
    let originB = UUID()
    let lines = RecordingAttachLines()

    let origin = RemoteBinding.Origin(host: "origin", endpoint: ControlZmxEndpoint(executable: "/a/zmx", socketDirectory: "/tmp/z"),
                                      sessionName: "work")

    private func attached() throws -> (AppStore, Session) {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "origin"))
        store.toggleSplit(session.id)
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        store.bindRemote(RemoteBinding(remoteSessionID: "origin", daemonsByLocalPane: [
            session.paneIdentity: ZmxSupport.daemonName(for: originA),
            try #require(session.splitPaneIdentity): ZmxSupport.daemonName(for: originB),
        ], presentationVersion: 1, origin: origin), forSession: session.id)
        return (store, session)
    }

    private func attachedAlone(headless: Bool = false) throws -> (AppStore, Session) {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "origin"))
        session.surface = SpySurface()
        store.bindRemote(RemoteBinding(remoteSessionID: "origin", daemonsByLocalPane: [
            session.paneIdentity: ZmxSupport.daemonName(for: originA),
        ], presentationVersion: 1, origin: origin, originHeadless: headless), forSession: session.id)
        return (store, session)
    }

    private func scratchLayout(_ scratch: UUID?, shown: Bool?) -> PresentationLayout {
        PresentationLayout(panes: [originA], primary: originA, shown: false, scratch: scratch, scratchShown: shown)
    }

    @Test func aLocalPaneHeldExitIsIgnoredByTheRemoteHandlers() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", command: "sleep 1", wait: true))

        store.remotePaneHeld(session.paneIdentity, forSession: session.id)

        #expect(!store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))
        #expect(!store.canCloseRemovedRemotePane(session.paneIdentity, forSession: session.id))
        #expect(store.session(withID: session.id) != nil)
    }

    @Test func layoutReordersOnlyExistingReplicasAndKeepsFocusOnItsPane() throws {
        let (store, session) = try attached()
        let primary = session.paneIdentity
        let split = try #require(session.splitPaneIdentity)
        session.splitFocused = false
        session.splitRatio = 0.35
        let layout = PresentationLayout(panes: [originB, originA], primary: originB, axis: "horizontal", shown: false)

        #expect(store.applyRemoteLayout(layout, forSession: session.id, attach: lines).isEmpty)

        #expect(session.paneIdentity == split)
        #expect(session.splitPaneIdentity == primary)
        #expect(session.splitFocused)
        #expect(session.splitRatio == 0.35)
        #expect(session.splitAxis == .topBottom)
        #expect(!session.isSplit)
        #expect(session.hasSplit)
        let removal = PresentationLayout(panes: [originB], primary: originB, shown: false)
        #expect(store.applyRemoteLayout(removal, forSession: session.id, attach: lines) == [primary])
    }

    @Test func anEndedRowOffersEveryMappedReplicaForClosingWithNoLayout() throws {
        let (store, session) = try attached()
        let split = try #require(session.splitPaneIdentity)

        #expect(!store.canCloseRemovedRemotePane(session.paneIdentity, forSession: session.id))
        #expect(Set(store.remoteSessionEnded(forSession: session.id)) == [session.paneIdentity, split])

        #expect(store.canCloseRemovedRemotePane(session.paneIdentity, forSession: session.id))
        #expect(store.canCloseRemovedRemotePane(split, forSession: session.id))
        #expect(session.remotePresentation?.originEnded == true)
    }

    @Test(arguments: [false, true])
    func anEndedRowsLastPaneClosesTheRowAloneAndItsCompanionMovesUp(viaSplit: Bool) throws {
        let (store, session) = try attached()
        let workspace = try #require(store.currentWorkspaceID)
        let companion = try #require(store.addSession(toWorkspace: workspace, cwd: "/c"))
        companion.parentID = session.id
        _ = store.remoteSessionEnded(forSession: session.id)
        store.closeSplit(session.id)

        if viaSplit {
            store.closeSplitPane(session.id)
        } else {
            _ = store.closePrimaryPane(session.id)
        }

        #expect(store.session(withID: session.id) == nil)
        #expect(store.session(withID: companion.id) != nil)
        #expect(companion.parentID == nil)
    }

    @Test(arguments: [false, true])
    func anEndedRowKeepsALocalSplitAndAPendingOneKeepsItsPrimary(pending: Bool) throws {
        let (store, session) = try attached()
        store.closeSplit(session.id)
        store.toggleSplit(session.id)
        if !pending { session.splitSurface = SpySurface() }
        let local = try #require(session.splitPaneIdentity)

        let offered = store.remoteSessionEnded(forSession: session.id)

        #expect(offered == (pending ? [] : [session.paneIdentity]))
        #expect(!store.canCloseRemovedRemotePane(local, forSession: session.id))
    }

    @Test func anEndedRowKeptByALocalSplitDropsWhatTheOriginMirroredOnIt() throws {
        let (store, session) = try attached()
        store.closeSplit(session.id)
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        store.setRemoteConnection(.connected, forSession: session.id)
        store.applyRemoteContext("deploy", forSession: session.id)
        #expect(session.effectiveContext == "deploy")

        _ = store.remoteSessionEnded(forSession: session.id)

        #expect(session.effectiveContext == nil)
        #expect(store.session(withID: session.id) != nil)
    }

    @Test func anEndedRowShowsNoNoticeEvenWhileItsStreamNeverConnected() throws {
        let (store, session) = try attached()
        store.setRemoteConnection(.connecting, forSession: session.id)
        #expect(session.remoteRowNotice != nil)

        _ = store.remoteSessionEnded(forSession: session.id)

        #expect(session.remoteRowNotice == nil)
        store.setRemoteConnection(.failed("end of stream"), forSession: session.id)
        #expect(session.remoteRowNotice == nil)
    }

    @Test func anEndedRowAttachesNothingTheSavedLayoutStillLists() throws {
        let (store, session) = try attached()
        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, UUID()], primary: originA, shown: true),
                                    forSession: session.id, attach: lines)
        store.closeSplit(session.id)

        _ = store.remoteSessionEnded(forSession: session.id)
        store.attachOriginAdditions(forSession: session.id, attach: lines)

        #expect(!session.hasSplit)
        #expect(session.splitInitialCommand == nil)
    }

    @Test func aClosedReplicaIsNeverRecreated() throws {
        let (store, session) = try attached()
        store.closeSplit(session.id)
        let layout = PresentationLayout(panes: [originA, originB], primary: originA, axis: "horizontal", shown: true)

        #expect(store.applyRemoteLayout(layout, forSession: session.id, attach: lines).isEmpty)

        #expect(!session.hasSplit)
        #expect(session.splitPaneIdentity == nil)
        #expect(session.splitSurface == nil)
    }

    @Test(arguments: [false, true])
    func aLocalSplitIsNeitherReorderedNorHidden(pending: Bool) throws {
        let (store, session) = try attached()
        store.closeSplit(session.id)
        store.toggleSplit(session.id)
        if !pending { session.splitSurface = SpySurface() }
        let local = session.splitPaneIdentity
        let primary = session.paneIdentity
        let layout = PresentationLayout(panes: [originB, originA], primary: originB, axis: "horizontal", shown: false)

        #expect(store.applyRemoteLayout(layout, forSession: session.id, attach: lines).isEmpty)

        #expect(session.splitPaneIdentity == local)
        #expect(session.paneIdentity == primary)
        #expect(session.isSplit)
        #expect(session.splitAxis == .leftRight)
        let removed = PresentationLayout(panes: [originB], primary: originB, shown: false)
        _ = store.applyRemoteLayout(removed, forSession: session.id, attach: lines)
        #expect(store.canCloseRemovedRemotePane(primary, forSession: session.id) == !pending)
        #expect(!store.canCloseRemovedRemotePane(try #require(local), forSession: session.id))
    }

    @Test func aPaneTheOriginAddsAttachesIntoTheEmptySplitSlotOnce() throws {
        let (store, session) = try attachedAlone()
        let layout = PresentationLayout(panes: [originA, originB], primary: originA, axis: "horizontal", shown: true)

        #expect(store.applyRemoteLayout(layout, forSession: session.id, attach: lines).isEmpty)
        _ = store.applyRemoteLayout(layout, forSession: session.id, attach: lines)

        let split = try #require(session.splitPaneIdentity)
        #expect(session.hasSplit)
        #expect(session.isSplit)
        #expect(session.splitAxis == .topBottom)
        #expect(session.splitInitialCommand == "attach-pane \(ZmxSupport.daemonName(for: originB))")
        #expect(session.splitCommandWait)
        #expect(session.remotePresentation?.binding.localPane(forRemote: originB) == split)
        #expect(lines.panes.count == 1)
        #expect(lines.panes.first?.local == split)
    }

    @Test func aHiddenOriginSplitAttachesHidden() throws {
        let (store, session) = try attachedAlone()

        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, originB], primary: originA, axis: "vertical", shown: false),
                                    forSession: session.id, attach: lines)

        #expect(session.hasSplit)
        #expect(!session.isSplit)
        #expect(session.splitAxis == .leftRight)
    }

    @Test func aReplacementOriginSplitAttachesAfterTheOldOneClosedHere() throws {
        let (store, session) = try attachedAlone()
        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, originB], primary: originA, axis: "vertical", shown: true),
                                    forSession: session.id, attach: lines)
        store.closeSplit(session.id)
        let replacement = UUID()

        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, originB], primary: originA, axis: "vertical", shown: true),
                                    forSession: session.id, attach: lines)
        #expect(!session.hasSplit)
        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, replacement], primary: originA, axis: "vertical", shown: true),
                                    forSession: session.id, attach: lines)

        #expect(session.hasSplit)
        #expect(session.remotePresentation?.binding.localPane(forRemote: replacement) == session.splitPaneIdentity)
        #expect(lines.panes.map(\.daemon) == [ZmxSupport.daemonName(for: originB), ZmxSupport.daemonName(for: replacement)])
    }

    @Test func aPaneReplacingTheRowsOwnAttachesAsTheSplitAndTakesOverWhenTheOldOneExits() throws {
        let (store, session) = try attachedAlone()

        _ = store.applyRemoteLayout(PresentationLayout(panes: [originB], primary: originB, shown: false),
                                    forSession: session.id, attach: lines)

        #expect(session.hasSplit)
        #expect(!session.isSplit)
        #expect(session.splitSurface == nil)
        #expect(lines.panes.map(\.daemon) == [ZmxSupport.daemonName(for: originB)])
        let split = try #require(session.splitPaneIdentity)
        #expect(store.closePrimaryPane(session.id) == .promoted)
        #expect(store.session(withID: session.id) === session)
        #expect(session.paneIdentity == split)
    }

    @Test func aPaneTheOriginAddedAsItsPrimaryTakesThePrimarySlotInTheSameFrame() throws {
        let (store, session) = try attachedAlone()
        let replica = session.surface

        _ = store.applyRemoteLayout(PresentationLayout(panes: [originB, originA], primary: originB, axis: "vertical", shown: true),
                                    forSession: session.id, attach: lines)

        let binding = try #require(session.remotePresentation?.binding)
        #expect(binding.remotePane(forLocal: session.paneIdentity) == originB)
        #expect(binding.remotePane(forLocal: try #require(session.splitPaneIdentity)) == originA)
        #expect(session.surface == nil)
        #expect(session.splitSurface === replica)
        #expect(session.initialCommand == lines.panes.first.map { "attach-pane \($0.daemon)" })
    }

    @Test func aSwapArrivingBeforeTheAddedPaneHasASurfaceStillMovesIt() throws {
        let (store, session) = try attachedAlone()
        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, originB], primary: originA, axis: "vertical", shown: true),
                                    forSession: session.id, attach: lines)
        #expect(session.remotePresentation?.binding.remotePane(forLocal: session.paneIdentity) == originA)

        _ = store.applyRemoteLayout(PresentationLayout(panes: [originB, originA], primary: originB, axis: "vertical", shown: true),
                                    forSession: session.id, attach: lines)

        #expect(session.remotePresentation?.binding.remotePane(forLocal: session.paneIdentity) == originB)
        #expect(lines.panes.count == 1)
    }

    @Test func aPairWhoseSurfacesAreNotRealizedYetStillFollowsTheOriginsPrimary() throws {
        let (store, session) = try attached()
        (session.surface as? SpySurface)?.isRealized = false
        (session.splitSurface as? SpySurface)?.isRealized = false
        store.setSplitVisibility(session.id, shown: false)

        _ = store.applyRemoteLayout(PresentationLayout(panes: [originB, originA], primary: originB, axis: "vertical", shown: true),
                                    forSession: session.id, attach: lines)

        #expect(session.remotePresentation?.binding.remotePane(forLocal: session.paneIdentity) == originB)
        #expect(!session.isSplit)
    }

    @Test func aSlotARemovalFreedTakesThePaneTheSavedLayoutAdded() throws {
        let (store, session) = try attachedAlone()
        let replacement = UUID()
        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, originB], primary: originA, axis: "vertical", shown: true),
                                    forSession: session.id, attach: lines)
        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, replacement], primary: originA, axis: "vertical", shown: true),
                                    forSession: session.id, attach: lines)
        #expect(lines.panes.count == 1)

        store.closeSplit(session.id)
        store.attachOriginAdditions(forSession: session.id, attach: lines)

        #expect(session.hasSplit)
        #expect(session.remotePresentation?.binding.localPane(forRemote: replacement) == session.splitPaneIdentity)
        #expect(lines.panes.map(\.daemon) == [ZmxSupport.daemonName(for: originB), ZmxSupport.daemonName(for: replacement)])
    }

    @Test func aStoppedOriginScratchAttachesAgainOnceWhileTheLayoutStillListsIt() throws {
        let (store, session) = try attachedAlone()
        let scratch = UUID()
        _ = store.applyRemoteLayout(scratchLayout(scratch, shown: true), forSession: session.id, attach: lines)
        let client = try #require(session.scratchClientIdentity)
        session.scratchSurface = SpySurface(paneToken: client.uuidString)

        #expect(session.paneIdentity(for: StatusPane.scratch) == client)
        #expect(store.originScratchStopped(session.id) == client)
        #expect(store.replaceOriginScratchAttachment(session.id, identity: scratch, attach: lines))
        #expect(!store.replaceOriginScratchAttachment(session.id, identity: scratch, attach: lines))

        #expect(session.scratchSurface == nil)
        #expect(session.scratchActive)
        #expect(lines.scratches == [ZmxSupport.daemonName(for: scratch), ZmxSupport.daemonName(for: scratch)])
        #expect(lines.scratchLocals == [client, client])
        session.scratchSurface = SpySurface(paneToken: client.uuidString)
        _ = store.applyRemoteLayout(scratchLayout(UUID(), shown: true), forSession: session.id, attach: lines)
        #expect(store.originScratchStopped(session.id) == nil)
    }

    @Test func aStoppedOriginScratchAttachesAgainNamingTheAttachToReclaimFrom() throws {
        let (store, session) = try attachedAlone()
        let scratch = UUID()
        _ = store.applyRemoteLayout(scratchLayout(scratch, shown: true), forSession: session.id, attach: lines)
        let client = try #require(session.scratchClientIdentity)
        session.scratchSurface = SpySurface(paneToken: client.uuidString)

        _ = store.originScratchStopped(session.id)
        #expect(store.replaceOriginScratchAttachment(session.id, identity: scratch, attach: lines, reclaim: "n1"))

        #expect(lines.scratchReclaims == [nil, "n1"])
    }

    private func node(_ store: AppStore, _ session: Session) throws -> ControlSessionNode {
        let tree = store.controlTree(paneForeground: { _ in nil })
        return try #require(tree.workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString })
    }

    @Test func anAttachedRowReadsItsOriginsMailOnEveryPaneItShows() throws {
        let (store, session) = try attachedAlone()
        let scratch = UUID()
        let layout = PresentationLayout(panes: [originA, originB], primary: originA, axis: "vertical", shown: true,
                                        scratch: scratch, scratchShown: true)
        _ = store.applyRemoteLayout(layout, forSession: session.id, attach: lines)
        session.splitSurface = SpySurface()
        session.scratchSurface = SpySurface(paneToken: try #require(session.scratchClientIdentity).uuidString)

        store.applyRemoteMail(PresentationMail(panes: [originA.uuidString: 2, originB.uuidString: 1, scratch.uuidString: 3]),
                              forSession: session.id)

        let loaded = try node(store, session)
        #expect(loaded.surfaces?.first { $0.kind == "left" }?.pendingMessages == 2)
        #expect(loaded.surfaces?.first { $0.kind == "right" }?.pendingMessages == 1)
        #expect(loaded.surfaces?.first { $0.kind == "scratch" }?.pendingMessages == 3)
        #expect(loaded.scratchPendingMessages == 3)
    }

    @Test func anAttachedRowReadsNoMailFromAnEmptyMapAnOriginWithoutCountsOrAWithdrawnStream() throws {
        let (store, session) = try attachedAlone()
        let count = { store.pendingMessages(session, pane: session.paneIdentity, token: nil) }
        #expect(count() == nil)

        store.applyRemoteMail(PresentationMail(panes: [originA.uuidString: 1]), forSession: session.id)
        #expect(count() == 1)
        store.applyRemoteMail(PresentationMail(panes: [:]), forSession: session.id)
        #expect(count() == nil)

        store.applyRemoteMail(PresentationMail(panes: [originA.uuidString: 1]), forSession: session.id)
        store.applyRemoteMail(nil, forSession: session.id)
        #expect(count() == nil)

        store.applyRemoteMail(PresentationMail(panes: [originA.uuidString: 1]), forSession: session.id)
        store.withdrawRemoteReplicas(of: session)
        #expect(session.remotePresentation?.mail == nil)
    }

    @Test func aRemoteWindowRowKeepsReadingItsCatalog() throws {
        let store = makeStore()
        let row = try addAttachedRow(to: store, workspace: store.addWorkspace(name: "work").id, catalogOwned: true)
        let origin = try #require(row.remotePresentation?.binding.remotePane(forLocal: row.paneIdentity))
        row.catalogPanes = [row.paneIdentity: CatalogPane(identity: row.paneIdentity, daemon: "d", endpoint: ControlZmxEndpoint(executable: "/z", socketDirectory: "/s"),
                                                          pendingMessages: 4)]

        store.applyRemoteMail(PresentationMail(panes: [origin.uuidString: 9]), forSession: row.id)

        #expect(store.pendingMessages(row, pane: row.paneIdentity, token: nil) == 4)
    }

    // regression: two rows of one origin session shared the origin's scratch UUID as their lead and reconnect key
    @Test func twoRowsOfOneOriginSessionKeyTheirScratchesApart() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let rows = try (0..<2).map { _ in
            let row = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "origin"))
            row.surface = SpySurface()
            store.bindRemote(RemoteBinding(remoteSessionID: "origin", daemonsByLocalPane: [
                row.paneIdentity: ZmxSupport.daemonName(for: originA),
            ], presentationVersion: 1, origin: origin), forSession: row.id)
            return row
        }
        let scratch = UUID()

        for row in rows { _ = store.applyRemoteLayout(scratchLayout(scratch, shown: true), forSession: row.id, attach: lines) }

        let clients = rows.compactMap(\.scratchClientIdentity)
        #expect(clients.count == 2)
        #expect(Set(clients).count == 2)
        #expect(!clients.contains(scratch))
        #expect(rows.map(\.originScratch) == [scratch, scratch])
        #expect(rows.map { $0.paneIdentity(for: StatusPane.scratch) } == clients)
        #expect(rows.map { $0.paneToken(for: .scratch) } == clients.map(\.uuidString))
        #expect(zip(rows, clients).allSatisfy { $0.paneRole(forToken: $1.uuidString) == .scratch })
        #expect(lines.scratchLocals == clients)
        #expect(lines.scratches == [ZmxSupport.daemonName(for: scratch), ZmxSupport.daemonName(for: scratch)])
    }

    @Test func aReplacedOriginScratchGetsANewKeyAndARepeatedLayoutKeepsIt() throws {
        let (store, session) = try attachedAlone()
        _ = store.applyRemoteLayout(scratchLayout(UUID(), shown: false), forSession: session.id, attach: lines)
        let first = try #require(session.scratchClientIdentity)

        _ = store.applyRemoteLayout(scratchLayout(session.originScratch, shown: true), forSession: session.id, attach: lines)
        #expect(session.scratchClientIdentity == first)

        _ = store.applyRemoteLayout(scratchLayout(UUID(), shown: true), forSession: session.id, attach: lines)
        let second = try #require(session.scratchClientIdentity)
        #expect(second != first)

        _ = store.applyRemoteLayout(scratchLayout(nil, shown: false), forSession: session.id, attach: lines)
        #expect(session.scratchClientIdentity == nil)
    }

    @Test(arguments: [false, true])
    func theOriginScratchAttachesItsDaemonShownAndHidesWithTheOrigin(headless: Bool) throws {
        let (store, session) = try attachedAlone(headless: headless)
        let scratch = UUID()

        _ = store.applyRemoteLayout(scratchLayout(scratch, shown: true), forSession: session.id, attach: lines)

        let daemon = headless ? ZmxSupport.scratchDaemonName(for: scratch) : ZmxSupport.daemonName(for: scratch)
        #expect(session.scratchFollowsOrigin)
        #expect(session.originScratch == scratch)
        #expect(session.scratchActive)
        #expect(session.scratchCommand == "attach-scratch \(daemon)")
        #expect(session.remoteHost(for: .scratch) == "origin")
        session.scratchSurface = SpySurface()
        session.scratchCommand = nil

        _ = store.applyRemoteLayout(scratchLayout(scratch, shown: false), forSession: session.id, attach: lines)
        #expect(!session.scratchActive)
        #expect(session.scratchSurface != nil)
        _ = store.applyRemoteLayout(scratchLayout(scratch, shown: true), forSession: session.id, attach: lines)

        #expect(session.scratchActive)
        #expect(lines.scratches == [daemon])
    }

    @Test func aReplacedOriginScratchClosesTheOldAttach() throws {
        let (store, session) = try attachedAlone()
        let first = UUID(), second = UUID()
        _ = store.applyRemoteLayout(scratchLayout(first, shown: true), forSession: session.id, attach: lines)
        let old = SpySurface()
        session.scratchSurface = old

        _ = store.applyRemoteLayout(scratchLayout(second, shown: true), forSession: session.id, attach: lines)

        #expect(old.teardownCount == 1)
        #expect(session.scratchSurface == nil)
        #expect(session.scratchActive)
        #expect(session.originScratch == second)
        #expect(session.scratchCommand == "attach-scratch \(ZmxSupport.daemonName(for: second))")
    }

    @Test func aGoneOriginScratchClosesTheOneHere() throws {
        let (store, session) = try attachedAlone()
        let scratch = UUID()
        _ = store.applyRemoteLayout(scratchLayout(scratch, shown: true), forSession: session.id, attach: lines)
        session.scratchSurface = SpySurface()

        _ = store.applyRemoteLayout(scratchLayout(nil, shown: false), forSession: session.id, attach: lines)

        #expect(session.scratchSurface == nil)
        #expect(session.scratchDaemon == nil)
        #expect(!session.scratchActive)
        #expect(session.scratchFollowsOrigin)
    }

    @Test func anOriginPublishingAScratchReplacesTheScratchOfThisMac() throws {
        let (store, session) = try attachedAlone()
        let local = SpySurface()
        session.scratchSurface = local
        store.toggleScratch(session.id)

        _ = store.applyRemoteLayout(scratchLayout(nil, shown: false), forSession: session.id, attach: lines)

        #expect(local.teardownCount == 1)
        #expect(!session.scratchActive)
    }

    @Test func anOlderOriginLeavesTheScratchOfThisMac() throws {
        let (store, session) = try attachedAlone()
        session.scratchSurface = SpySurface()
        store.toggleScratch(session.id)

        _ = store.applyRemoteLayout(scratchLayout(nil, shown: nil), forSession: session.id, attach: lines)

        #expect(session.scratchSurface != nil)
        #expect(session.scratchActive)
        #expect(!session.scratchFollowsOrigin)
        #expect(session.originScratch == nil)
        #expect(session.remoteHost(for: .scratch) == nil)
    }

    @Test func originPublishesItsScratchOnShowHideAndEnd() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let sink = PresentationHubTests.Sink()
        try hub.subscribe(session: session.id, hello: PresentationHubTests.hello, sink: sink) {
            store.presentationSnapshot(forSession: session.id)
        }
        let scratch = UUID()
        func last() -> PresentationLayout? {
            guard case .layout(let layout) = sink.frames.last?.body else { return nil }
            return layout
        }

        store.toggleScratch(session.id)
        store.recordLiveScratch(session.id, identity: scratch)
        #expect(last()?.scratch == scratch)
        #expect(last()?.scratchShown == true)
        session.scratchSurface = SpySurface(paneToken: scratch.uuidString)
        store.toggleScratch(session.id)
        #expect(last()?.scratchShown == false)
        store.toggleScratch(session.id)
        store.closeScratch(session.id)

        #expect(last()?.scratch == nil)
        #expect(last()?.scratchShown == false)
    }

    @Test func anUnrealizedReplicaIsNotShownByALayout() throws {
        let (store, session) = try attached()
        (session.splitSurface as? SpySurface)?.isRealized = false
        store.setSplitVisibility(session.id, shown: false)

        _ = store.applyRemoteLayout(PresentationLayout(panes: [originA, originB], primary: originA,
                                                       axis: "vertical", shown: true), forSession: session.id, attach: lines)

        #expect(!session.isSplit)
    }

    @Test func originPublishesModelMembershipOncePerChangeAndSeedsLateSubscribers() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        session.surface = SpySurface(backedByZmx: true)
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let sink = PresentationHubTests.Sink()
        try hub.subscribe(session: session.id, hello: PresentationHubTests.hello, sink: sink) {
            store.presentationSnapshot(forSession: session.id)
        }
        store.toggleSplit(session.id)
        let split = try #require(session.splitPaneIdentity)
        #expect(session.splitSurface == nil)
        #expect(sink.frames.last?.body == .layout(PresentationLayout(panes: [session.paneIdentity, split], primary: session.paneIdentity,
                                                                    axis: "vertical", shown: true, scratchShown: false)))
        let count = sink.frames.count
        store.setSplitVisibility(session.id, shown: true)
        #expect(sink.frames.count == count)
        store.setSplitVisibility(session.id, shown: false)
        store.setSplitVisibility(session.id, shown: true, axis: .topBottom)
        session.splitSurface = SpySurface(backedByZmx: true)
        #expect(store.swapPanes(session.id) == nil)
        store.closePrimaryPane(session.id)
        #expect(sink.frames.count == count + 4)
        let late = PresentationHubTests.Sink()
        try hub.subscribe(session: session.id, hello: PresentationHubTests.hello, sink: late) {
            store.presentationSnapshot(forSession: session.id)
        }
        #expect(late.frames.last?.body == .snapshot(store.presentationSnapshot(forSession: session.id)))
        #expect(store.presentationSnapshot(forSession: session.id).layout?.panes == [session.paneIdentity])
    }

    @Test func anAttachedRowNeverPublishesLayout() throws {
        let (store, session) = try attached()
        let hub = PresentationHub(staleTimeout: 30)
        let sink = PresentationHubTests.Sink()
        store.presentationHub = hub
        try hub.subscribe(session: session.id, hello: PresentationHubTests.hello, sink: sink) {
            store.presentationSnapshot(forSession: session.id)
        }
        store.setSplitVisibility(session.id, shown: false)
        store.closeSplit(session.id)
        #expect(sink.frames.count == 2)
        #expect(store.presentationSnapshot(forSession: session.id).layout == nil)
    }

    @Test func aReplicaThatAttachedAgainIsNoLongerHeld() throws {
        let (store, session) = try attached()
        store.remotePaneHeld(session.paneIdentity, forSession: session.id)
        #expect(store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))

        store.remotePaneResumed(session.paneIdentity, forSession: session.id)

        #expect(!store.remotePaneIsHeld(session.paneIdentity, forSession: session.id))
    }
}
