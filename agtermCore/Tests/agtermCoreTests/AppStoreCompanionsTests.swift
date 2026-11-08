import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreCompanionsTests {
    private func refusal(_ result: Result<Session, CompanionRefusal>) -> CompanionRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    private func convertRefusal(_ result: Result<Session, ConvertRefusal>) -> ConvertRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    @Test func aCompanionLandsAfterTheParentsLastCompanion() throws {
        let g = try CompanionGroup()
        let (store, parent, first, second, after) = (g.store, g.parent, g.first, g.second, g.after)

        #expect(g.order == [parent.id, first.id, second.id, after.id])
        #expect(first.parentID == parent.id)
        #expect(second.parentID == parent.id)
        #expect(store.companions(of: parent.id).map(\.id) == [first.id, second.id])
        #expect(store.parent(of: first) === parent)
        #expect(store.parent(of: parent) == nil)
    }

    @Test func aPageCompanionShowsItsPageFullSizeUnderTheParent() throws {
        let g = try CompanionGroup()
        let overlay = HtmlOverlay(source: .file(path: "/tmp/a/page.html", grantRoot: nil))

        let page = try g.store.addPageCompanion(to: g.first.id, overlay: overlay, name: "docs").get()

        #expect(page.content == .page)
        #expect(page.parentID == g.parent.id)
        #expect(g.order == [g.parent.id, g.first.id, g.second.id, page.id, g.after.id])
        #expect(page.htmlOverlay?.id == overlay.id)
        #expect(page.overlaySizePercent == nil)
        #expect(page.locallyManagedPaneIdentities.isEmpty)
        #expect(page.hideableOverlaySlots(nil).isEmpty)
    }

    @Test func aPageCompanionIsNamedForItsPageAndReportsItsParentsCwd() throws {
        let g = try CompanionGroup()
        let page = try g.store.addPageCompanion(to: g.parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/a/report.html", grantRoot: nil))).get()

        #expect(page.displayName == "report.html")
        g.store.renameSession(page.id, to: "notes")
        #expect(page.displayName == "notes")
        let node = g.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == page.id.uuidString }
        #expect(node?.cwd == g.parent.effectiveCwd)
    }

    @Test func aPageCompanionRefusesEverythingThatWouldCoverFloatOrHideItsPage() throws {
        let g = try CompanionGroup()
        let page = try g.store.addPageCompanion(to: g.parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()

        #expect(!g.store.openOverlay(page.id, command: "top"))
        #expect(g.store.openPaneOverlay(page.id, pane: .left, command: "top") != nil)
        #expect(!g.store.resizeOverlay(page.id, sizePercent: 50))
        #expect(g.store.applyOverlayVisibility(page.id, pane: nil, mode: .hide) != nil)
        #expect(g.store.applyOverlayVisibility(page.id, pane: nil, mode: .show) == nil)
        #expect(!page.overlayHidden(nil))
        #expect(page.htmlOverlay != nil)
    }

    @Test func aPageCompanionIsSavedOnCreationAndArchivedWithItsParent() throws {
        let (store, recent, persistence) = makeStoreWithRecentClosed()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/parent"))
        let page = try store.addPageCompanion(to: parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()
        let descriptor = PageSnapshot(source: .file(path: "/tmp/p.html", grantRoot: nil))

        #expect(persistence.load().workspaces.flatMap(\.sessions).first { $0.id == page.id }?.page == descriptor)
        store.closeSession(parent.id)
        #expect(recent.load().first?.session?.companions?.map(\.id) == [page.id])
        #expect(recent.load().first?.session?.companions?.first?.page == descriptor)
    }

    @Test func closingThePageClosesItsCompanion() throws {
        let g = try CompanionGroup()
        let page = try g.store.addPageCompanion(to: g.parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()

        #expect(g.store.closeOverlay(page.id))

        #expect(g.store.session(withID: page.id) == nil)
        #expect(g.store.session(withID: g.parent.id) != nil)
    }

    @Test func aPageCompanionHasNoDashboardCell() throws {
        let g = try CompanionGroup()
        let page = try g.store.addPageCompanion(to: g.parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()

        let cells = g.store.dashboardPaneCells(for: [ResolvedDashboardTarget(session: page.id, pane: nil),
                                                     ResolvedDashboardTarget(session: g.parent.id, pane: nil)])

        #expect(cells.map(\.session) == [g.parent.id])
    }

    @Test func duplicateAsCompanionCopiesTheLayoutAndRunsEachProgramAsItsCommand() throws {
        let g = try CompanionGroup()

        let copy = try g.store.duplicateAsCompanion(
            of: g.first.id, left: .program(argv: ["htop", "-d", "5"], workingDirectory: "/srv"),
            right: .shell(workingDirectory: "/var/log"), axis: .topBottom, ratio: 0.3).get()

        #expect(copy.parentID == g.parent.id)
        #expect(g.order == [g.parent.id, g.first.id, g.second.id, copy.id, g.after.id])
        #expect(copy.initialCwd == "/srv")
        #expect(copy.initialCommand == "'htop' '-d' '5'")
        #expect(!copy.commandWait)
        #expect(copy.isSplit && copy.splitAxis == .topBottom)
        #expect(copy.splitRatio == 0.3)
        #expect(copy.initialSplitCwd == "/var/log")
        #expect(copy.splitInitialCommand == nil)
    }

    // a duplicated split opened like a new split and focused its right pane
    @Test func duplicateAsCompanionFocusesTheLeftPaneOfTheCopiedSplit() throws {
        let g = try CompanionGroup()
        g.store.setSplitVisibility(g.first.id, shown: true)
        #expect(g.first.focusedPane == .right)

        let copy = try g.store.duplicateAsCompanion(
            of: g.first.id, left: .shell(workingDirectory: "/srv"), right: .shell(workingDirectory: "/var/log")).get()

        #expect(copy.hasSplit)
        #expect(copy.focusedPane == .left)
    }

    // a copied codex kept its parent's session id in argv and sent its replies into the parent's pane
    @Test func duplicateAsCompanionRebindsTheSourcesIdentitiesInBothPanes() throws {
        let g = try CompanionGroup()
        g.store.setSplitVisibility(g.first.id, shown: true)
        let source = g.first
        let sourceSplit = try #require(source.splitPaneIdentity)
        let unrelated = UUID().uuidString
        let mixed = source.id.uuidString.prefix(8).lowercased() + source.id.uuidString.dropFirst(8)

        let copy = try g.store.duplicateAsCompanion(
            of: source.id,
            left: .program(argv: ["codex", "-c", "set.AGTERM_SESSION_ID=\"\(source.id.uuidString)\"",
                                  "--peer", sourceSplit.uuidString.lowercased(), "--window", unrelated],
                           workingDirectory: "/srv"),
            right: .program(argv: ["tool", ZmxSupport.daemonName(for: source.paneIdentity),
                                   "--pane=\(source.paneIdentity.uuidString)", "--session=\(mixed)"],
                            workingDirectory: "/var/log")).get()
        let copySplit = try #require(copy.splitPaneIdentity)

        #expect(copy.initialCommand == CommandRestore.shellQuotedLine(
            ["codex", "-c", "set.AGTERM_SESSION_ID=\"\(copy.id.uuidString)\"",
             "--peer", copySplit.uuidString.lowercased(), "--window", unrelated]))
        #expect(copy.splitInitialCommand == CommandRestore.shellQuotedLine(
            ["tool", ZmxSupport.daemonName(for: copy.paneIdentity),
             "--pane=\(copy.paneIdentity.uuidString)", "--session=\(copy.id.uuidString)"]))
        #expect(copy.initialCwd == "/srv")
        #expect(copy.initialSplitCwd == "/var/log")
    }

    @Test func duplicateAsCompanionPersistsTheReboundCommandOfASinglePane() throws {
        let (store, _, persistence) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let source = try #require(store.addSession(toWorkspace: work.id, cwd: "/parent"))

        let copy = try store.duplicateAsCompanion(
            of: source.id, left: .program(argv: ["codex", "--session", source.id.uuidString], workingDirectory: "/srv"),
            right: nil).get()

        let saved = persistence.load().workspaces.flatMap(\.sessions).first { $0.id == copy.id }
        #expect(saved?.initialCommand == CommandRestore.shellQuotedLine(["codex", "--session", copy.id.uuidString]))
    }

    @Test func duplicateAsCompanionOfASinglePaneMakesNoSplit() throws {
        let g = try CompanionGroup()

        let copy = try g.store.duplicateAsCompanion(of: g.parent.id, left: .shell(workingDirectory: "/srv"), right: nil).get()

        #expect(copy.initialCommand == nil)
        #expect(!copy.hasSplit)
    }

    @Test func aCompanionTakesItsCreationTint() throws {
        let g = try CompanionGroup()

        let tinted = try g.store.addCompanion(to: g.parent.id, options: CompanionOptions(tint: SidebarTint(color: .blue))).get()

        #expect(tinted.tint == SidebarTint(color: .blue))
    }

    @Test func aCompanionOfACompanionBecomesASibling() throws {
        let g = try CompanionGroup()
        let (store, parent, first, second, after) = (g.store, g.parent, g.first, g.second, g.after)

        let third = try store.addCompanion(to: first.id).get()

        #expect(third.parentID == parent.id)
        #expect(g.order == [parent.id, first.id, second.id, third.id, after.id])
    }

    @Test func aCompanionStartsInTheParentsCwdUnlessGivenOne() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/parent/dir"))

        let companion = try store.addCompanion(to: parent.id, options: CompanionOptions(command: "lazygit", name: "git", wait: true)).get()

        #expect(companion.initialCwd == "/parent/dir")
        #expect(companion.initialCommand == "lazygit")
        #expect(companion.customName == "git")
        #expect(companion.commandWait)
        #expect(store.selectedSessionID == companion.id)
    }

    @Test func aBackgroundCompanionKeepsTheSelection() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/parent"))

        _ = try store.addCompanion(to: parent.id, options: CompanionOptions(select: false)).get()

        #expect(store.selectedSessionID == parent.id)
    }

    @Test func aRemoteParentIsRefused() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/r", remoteHost: "buildbox"))

        #expect(refusal(store.addCompanion(to: remote.id)) == .remoteParent)
        #expect(refusal(store.addCompanion(to: UUID())) == .noSuchSession)
        #expect(store.workspaces[0].sessions.count == 1)
    }

    @Test(arguments: [1, 2, 3])
    func aTopLevelSessionInsertedInsideAGroupLandsAfterIt(index: Int) throws {
        let g = try CompanionGroup()
        let (store, workspace, parent, first, second, after) = (g.store, g.work, g.parent, g.first, g.second, g.after)

        let inserted = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/new", at: index))

        #expect(g.order == [parent.id, first.id, second.id, inserted.id, after.id])
    }

    @Test func insertionBeforeTheParentStaysBeforeTheGroup() throws {
        let g = try CompanionGroup()
        let (store, workspace, parent, first, second, after) = (g.store, g.work, g.parent, g.first, g.second, g.after)

        let inserted = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/new", at: 0))

        #expect(g.order == [inserted.id, parent.id, first.id, second.id, after.id])
    }

    @Test func plainDuplicateOfAParentLandsAfterItsGroup() throws {
        let g = try CompanionGroup()
        let (store, parent, first, second, after) = (g.store, g.parent, g.first, g.second, g.after)

        let duplicate = try #require(store.duplicateSession(parent.id))

        #expect(duplicate.parentID == nil)
        #expect(g.order == [parent.id, first.id, second.id, duplicate.id, after.id])
    }

    @Test func anUndoneCloseOfATopLevelSessionLandsOutsideAGroupThatGrewIntoItsSlot() throws {
        let g = try CompanionGroup()
        #expect(g.store.softCloseSession(g.after.id))
        let third = try g.store.addCompanion(to: g.parent.id).get()

        #expect(g.store.undoPendingClose())

        #expect(g.order == [g.parent.id, g.first.id, g.second.id, third.id, g.after.id])
    }

    @Test func closingAParentClosesItsCompanionsAndRecordsOneGroupEntry() throws {
        let (store, recent, _) = makeStoreWithRecentClosed()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/parent"))
        let other = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/other"))
        let first = try store.addCompanion(to: parent.id).get()
        let second = try store.addCompanion(to: parent.id).get()
        store.selectSession(second.id)

        store.closeSession(parent.id)

        #expect(store.workspaces[0].sessions.map(\.id) == [other.id])
        #expect(store.selectedSessionID == other.id)
        let items = recent.load()
        #expect(items.count == 1)
        #expect(items.first?.session?.snapshot.id == parent.id)
        #expect(items.first?.session?.companions?.map(\.id) == [first.id, second.id])
    }

    @Test func closingACompanionClosesOnlyIt() throws {
        let g = try CompanionGroup()

        g.store.closeSession(g.first.id)

        #expect(g.order == [g.parent.id, g.second.id, g.after.id])
    }

    @Test func softClosingAParentIsOneUndoForTheWholeGroup() throws {
        let (store, recent, _) = makeStoreWithRecentClosed()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/parent"))
        let after = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/after"))
        let first = try store.addCompanion(to: parent.id).get()
        let second = try store.addCompanion(to: parent.id).get()

        #expect(store.softCloseSession(parent.id, grace: 60))
        #expect(store.workspaces[0].sessions.map(\.id) == [after.id])
        #expect(recent.load().count == 1)
        #expect(recent.load().first?.session?.companions?.map(\.id) == [first.id, second.id])

        #expect(store.undoPendingClose())
        #expect(store.workspaces[0].sessions.map(\.id) == [parent.id, first.id, second.id, after.id])
        #expect(first.parentID == parent.id)
        #expect(second.parentID == parent.id)
        #expect(recent.load().isEmpty)
    }

    @Test func onlyAParentWithCompanionsFolds() throws {
        let g = try CompanionGroup()

        #expect(g.store.setSessionExpanded(g.parent.id, expanded: false))
        #expect(!g.parent.isExpanded)
        #expect(!g.store.setSessionExpanded(g.after.id, expanded: false))
        #expect(g.after.isExpanded)
        #expect(!g.store.setSessionExpanded(g.first.id, expanded: false))
        #expect(g.first.isExpanded)
    }

    @Test func blockedCompletedAndUnreadCompanionsNeedAttention() throws {
        let g = try CompanionGroup()
        let third = try g.store.addCompanion(to: g.parent.id).get()
        let fourth = try g.store.addCompanion(to: g.parent.id).get()
        g.store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: g.first.id)
        g.store.setAgentIndicator(AgentIndicator(status: .active), forSession: g.second.id)
        g.store.setAgentIndicator(AgentIndicator(status: .completed), forSession: third.id)
        fourth.unseenCount = 2
        g.store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: g.parent.id)

        #expect(g.store.companionsNeedingAttention(of: g.parent.id).map(\.id) == [g.first.id, third.id, fourth.id])
        #expect(g.store.companionsNeedingAttention(of: g.after.id).isEmpty)
    }

    @Test func onlyAMoveInsideItsGroupIsOfferedForACompanion() throws {
        let g = try CompanionGroup()

        #expect(g.store.canMoveSessions([g.second.id], toWorkspace: g.work.id, at: 1))
        #expect(g.store.canMoveSessions([g.second.id], toWorkspace: g.work.id))
        #expect(!g.store.canMoveSessions([g.second.id], toWorkspace: g.work.id, at: 0))
        #expect(!g.store.canMoveSessions([g.second.id], toWorkspace: g.work.id, at: 3))
        #expect(!g.store.canMoveSessions([g.second.id], toWorkspace: g.personal.id, at: 0))
        #expect(g.store.canMoveSessions([g.parent.id], toWorkspace: g.personal.id))
    }

    @Test func aCompanionBatchedWithASessionAlreadyThereIsNotOfferedThatWorkspace() throws {
        let g = try CompanionGroup()
        let resident = try #require(g.store.addSession(toWorkspace: g.personal.id, cwd: "/q"))

        #expect(!g.store.canMoveSessions([g.first.id, resident.id], toWorkspace: g.personal.id))
        #expect(g.store.moveSessions([g.first.id, resident.id], toWorkspace: g.personal.id) == 0)
    }

    @Test func aFlaggedCompanionOfAnUnflaggedParentCannotLeaveItsGroupInTheFlaggedTree() throws {
        let g = try CompanionGroup()
        g.store.setFlag(true, forSessions: [g.first.id, g.after.id])
        let resolution = try #require(SidebarDrop.resolveSessions(
            sources: [SidebarDrop.SessionSource(workspace: g.work.id, index: 1)],
            target: .workspaceRow(id: g.work.id, sessionCount: 4),
            childIndex: SidebarDrop.flaggedTreeChildIndex(visibleIndices: [1, 3], slot: 2)))

        #expect(!g.store.canMoveSessions([g.first.id], toWorkspace: g.work.id, at: resolution.destination))
        #expect(g.store.moveSessions([g.first.id], toWorkspace: g.work.id, at: resolution.destination) == 0)
        #expect(g.order == [g.parent.id, g.first.id, g.second.id, g.after.id])
    }

    @Test func anUndoneCompanionCloseFollowsAParentThatMovedAway() throws {
        let store = makeStore()
        let home = store.addWorkspace(name: "home")
        let away = store.addWorkspace(name: "away")
        let parent = try #require(store.addSession(toWorkspace: home.id, cwd: "/parent"))
        let companion = try store.addCompanion(to: parent.id).get()
        #expect(store.softCloseSession(companion.id, grace: 60))
        #expect(store.moveSession(parent.id, toWorkspace: away.id))

        #expect(store.undoPendingClose())

        #expect(companion.parentID == parent.id)
        #expect(store.workspaces.first { $0.id == away.id }?.sessions.map(\.id) == [parent.id, companion.id])
        #expect(store.workspaces.first { $0.id == home.id }?.sessions.isEmpty == true)
    }

    // a companion parked by a soft close came back top-level after its parent closed for good
    @Test func aParentsHardCloseEndsTheUndoOfItsParkedCompanions() throws {
        let store = makeStore()
        let home = store.addWorkspace(name: "home")
        let parent = try #require(store.addSession(toWorkspace: home.id, cwd: "/parent"))
        let other = try #require(store.addSession(toWorkspace: home.id, cwd: "/other"))
        let parked = try store.addCompanion(to: parent.id).get()
        let mate = try store.addCompanion(to: other.id).get()
        #expect(store.softCloseSessions([parked.id, mate.id], grace: 60))

        store.closeSession(parent.id)

        #expect(store.pendingCloseSession(withID: parked.id) == nil)
        #expect(store.undoPendingClose())
        #expect(store.session(withID: parked.id) == nil)
        #expect(mate.parentID == other.id && store.session(withID: mate.id) != nil)
    }

    // a hard workspace delete left the parked companion of a parent it removed undoable, to come back top-level
    @Test func aHardWorkspaceDeleteEndsTheUndoOfItsParentsParkedCompanions() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        let kept = store.addWorkspace(name: "kept")
        let parent = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/parent"))
        let other = try #require(store.addSession(toWorkspace: kept.id, cwd: "/other"))
        let parked = try store.addCompanion(to: parent.id).get()
        let mate = try store.addCompanion(to: other.id).get()
        #expect(store.softCloseSessions([parked.id, mate.id], grace: 60))

        store.removeWorkspace(doomed.id)

        #expect(store.pendingCloseSession(withID: parked.id) == nil)
        #expect(store.undoPendingClose())
        #expect(store.session(withID: parked.id) == nil)
        #expect(mate.parentID == other.id && store.session(withID: mate.id) != nil)
    }

    @Test func aParentsLastPaneExitStartsAFreshShellInItsLastCwd() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/start", command: "lazygit", wait: true))
        _ = try store.addCompanion(to: parent.id).get()
        let surface = SpySurface()
        parent.surface = surface
        parent.currentCwd = "/moved"
        parent.pendingForegroundCommand = ["htop"]
        let identity = parent.paneIdentity

        #expect(store.closePrimaryPane(parent.id) == .respawned)

        #expect(store.session(withID: parent.id) != nil)
        #expect(surface.teardownCount == 1)
        #expect(parent.surface == nil)
        #expect(parent.paneIdentity == identity)
        #expect(parent.initialCwd == "/moved")
        #expect(parent.initialCommand == nil)
        #expect(!parent.commandWait)
        #expect(parent.pendingForegroundCommand == nil)
        #expect(parent.primaryRespawns == 1)
    }

    // a shell exiting as soon as it started respawned forever, saving the store on every turn
    @Test func aParentWhoseRespawnedShellExitsAtOnceClosesWithItsGroup() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/start"))
        let companion = try store.addCompanion(to: parent.id).get()
        let start = Date(timeIntervalSince1970: 1_000)

        parent.surface = SpySurface()
        #expect(store.closePrimaryPane(parent.id, now: start) == .respawned)
        parent.surface = SpySurface()
        #expect(store.closePrimaryPane(parent.id, now: start.addingTimeInterval(1)) == .closed)

        #expect(store.session(withID: parent.id) == nil)
        #expect(store.session(withID: companion.id) == nil)
    }

    @Test func aRespawnedShellThatRanAWhileRespawnsAgain() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/start"))
        _ = try store.addCompanion(to: parent.id).get()
        let start = Date(timeIntervalSince1970: 1_000)

        parent.surface = SpySurface()
        #expect(store.closePrimaryPane(parent.id, now: start) == .respawned)
        parent.surface = SpySurface()
        #expect(store.closePrimaryPane(parent.id, now: start.addingTimeInterval(60)) == .respawned)
        #expect(parent.primaryRespawns == 2)
    }

    @Test func aRespawnedShellExitingAtOnceThroughItsSplitSlotClosesTheGroup() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/start"))
        _ = try store.addCompanion(to: parent.id).get()
        let start = Date(timeIntervalSince1970: 1_000)

        parent.surface = SpySurface()
        #expect(store.closePrimaryPane(parent.id, now: start) == .respawned)
        store.closeSplitPane(parent.id, now: start.addingTimeInterval(1))

        #expect(store.session(withID: parent.id) == nil)
    }

    // a parked parent made final alone left its parked companions undoable, and undo detached them
    @Test func finalizingAParkedParentEndsTheUndoOfItsParkedCompanions() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/parent"))
        let companion = try store.addCompanion(to: parent.id).get()
        let other = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/other"))
        #expect(store.softCloseSessions([parent.id, companion.id, other.id], grace: 60))

        #expect(store.finalizePendingClose(ofSession: parent.id))

        #expect(store.pendingCloseSession(withID: companion.id) == nil)
        #expect(store.undoPendingClose())
        #expect(store.session(withID: companion.id) == nil)
        #expect(store.session(withID: other.id) != nil)
    }

    @Test func aPrimaryExitPromotesALiveSplitBeforeAnyRespawn() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/start"))
        _ = try store.addCompanion(to: parent.id).get()
        store.toggleSplit(parent.id)
        parent.surface = SpySurface()
        parent.splitSurface = SpySurface()

        #expect(store.closePrimaryPane(parent.id) == .promoted)
        #expect(parent.primaryRespawns == 0)

        #expect(store.closePrimaryPane(parent.id) == .respawned)
        #expect(store.session(withID: parent.id) != nil)
        #expect(parent.primaryRespawns == 1)
    }

    @Test func aSessionWithoutCompanionsStillClosesOnItsLastPaneExit() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/start"))
        session.surface = SpySurface()

        #expect(store.closePrimaryPane(session.id) == .closed)
        #expect(store.session(withID: session.id) == nil)
    }

    @Test func regroupingDropsLinksWithoutATopLevelParentAndRebuildsOrder() {
        let parent = Session(initialCwd: "/p")
        let companion = Session(initialCwd: "/c")
        companion.parentID = parent.id
        let orphan = Session(initialCwd: "/o")
        orphan.parentID = UUID()
        let chained = Session(initialCwd: "/x")
        chained.parentID = companion.id
        let other = Session(initialCwd: "/other")

        let regrouped = AppStore.regroupedCompanions([companion, other, orphan, parent, chained])

        #expect(regrouped.map(\.id) == [other.id, orphan.id, parent.id, companion.id, chained.id])
        #expect(orphan.parentID == nil)
        #expect(chained.parentID == nil)
        #expect(companion.parentID == parent.id)
    }

    @Test func convertNestsTheSameSessionUnderAFreshSessionInItsSlot() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let before = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/before"))
        let task = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/start", name: "task"))
        let after = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/after"))
        task.currentCwd = "/work/task"
        store.setFlag(true, forSession: task.id)
        let surface = SpySurface()
        task.surface = surface
        let pane = task.paneIdentity
        store.selectSession(before.id)

        let fresh = try store.convertToCompanion(task.id).get()

        #expect(store.workspaces[0].sessions.map(\.id) == [before.id, fresh.id, task.id, after.id])
        #expect(fresh.parentID == nil)
        #expect(fresh.initialCwd == "/work/task")
        #expect(fresh.customName == nil)
        #expect(!fresh.flagged)
        #expect(fresh.isExpanded)
        #expect(store.session(withID: task.id) === task)
        #expect(task.parentID == fresh.id)
        #expect(task.surface === surface)
        #expect(task.paneIdentity == pane)
        #expect(task.displayName == "task")
        #expect(task.flagged)
        #expect(store.selectedSessionID == task.id)
    }

    @Test func convertCarriesTheSessionsCompanionsUnderTheFreshParent() throws {
        let g = try CompanionGroup()

        let fresh = try g.store.convertToCompanion(g.parent.id).get()

        #expect(g.order == [fresh.id, g.parent.id, g.first.id, g.second.id, g.after.id])
        #expect([g.parent, g.first, g.second].allSatisfy { $0.parentID == fresh.id })
        #expect(g.store.companions(of: fresh.id).map(\.id) == [g.parent.id, g.first.id, g.second.id])
    }

    @Test func convertRefusesACompanionARemoteRowAndAnUnknownSession() throws {
        let g = try CompanionGroup()
        let remote = try #require(g.store.addSession(toWorkspace: g.work.id, cwd: "/r", remoteHost: "buildbox"))
        let before = g.order

        #expect(convertRefusal(g.store.convertToCompanion(g.first.id)) == .alreadyCompanion)
        #expect(convertRefusal(g.store.convertToCompanion(remote.id)) == .remoteSession)
        #expect(convertRefusal(g.store.convertToCompanion(UUID())) == .noSuchSession)
        #expect(g.order == before)
        #expect(g.first.parentID == g.parent.id)
    }

    @Test func convertRefusalsCarryTheirMessage() {
        #expect(ConvertRefusal.alreadyCompanion.message == "already a companion")
        #expect(ConvertRefusal.remoteSession.message == "convert it on the Mac it runs on")
        #expect(ConvertRefusal.noSuchSession.message == "no such session")
    }

    @Test func convertAnnouncesOnlyTheFreshSession() throws {
        let events = CompanionEventKinds()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir), controlEventSink: { events.kinds.append($0.kind) })
        let workspace = store.addWorkspace(name: "work")
        let task = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/task"))
        events.kinds.removeAll()

        _ = try store.convertToCompanion(task.id).get()

        #expect(events.kinds.filter { $0 == .sessionCreated }.count == 1)
        #expect(!events.kinds.contains(.sessionClosed))
        #expect(!events.kinds.contains(.sessionSelected))
        #expect(events.kinds.contains(.treeChanged))
    }

    @Test func aConvertedSessionClosesOnItsExitWhileTheFreshParentRespawns() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let task = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/task"))
        _ = try store.addCompanion(to: task.id).get()
        let fresh = try store.convertToCompanion(task.id).get()
        task.surface = SpySurface()
        fresh.surface = SpySurface()

        #expect(store.closePrimaryPane(task.id) == .closed)
        #expect(store.session(withID: task.id) == nil)
        #expect(store.closePrimaryPane(fresh.id) == .respawned)
        #expect(store.session(withID: fresh.id) != nil)
    }

    @Test func aConvertedGroupRoundTripsThroughSnapshot() throws {
        let g = try CompanionGroup()
        let fresh = try g.store.convertToCompanion(g.parent.id).get()

        let restored = makeStore()
        restored.restore(from: g.store.snapshot())

        let sessions = try #require(restored.workspaces.first).sessions
        #expect(sessions.map(\.id) == [fresh.id, g.parent.id, g.first.id, g.second.id, g.after.id])
        #expect(sessions[0].parentID == nil)
        #expect(sessions[1...3].allSatisfy { $0.parentID == fresh.id })
    }

    @Test func aConvertedGroupClosesAndReopensWhole() throws {
        let (store, recent, _) = makeStoreWithRecentClosed()
        let workspace = store.addWorkspace(name: "work")
        let task = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/task"))
        let other = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/other"))
        let old = try store.addCompanion(to: task.id).get()
        let fresh = try store.convertToCompanion(task.id).get()

        store.closeSession(fresh.id)

        #expect(store.workspaces[0].sessions.map(\.id) == [other.id])
        let item = try #require(recent.load().first)
        #expect(item.session?.snapshot.id == fresh.id)
        #expect(item.session?.companions?.map(\.id) == [task.id, old.id])
        #expect(store.restoreRecentClosed(item))
        let sessions = store.workspaces[0].sessions
        #expect(sessions.map(\.id) == [fresh.id, task.id, old.id, other.id])
        #expect(sessions[1...2].allSatisfy { $0.parentID == fresh.id })
    }

    @Test func anUndoneCompanionCloseFollowsItsParentIntoTheConvertedGroup() throws {
        let g = try CompanionGroup()
        #expect(g.store.softCloseSession(g.first.id, grace: 60))
        let fresh = try g.store.convertToCompanion(g.parent.id).get()

        #expect(g.store.undoPendingClose())

        #expect(g.first.parentID == fresh.id)
        #expect(Set(g.store.companions(of: fresh.id).map(\.id)) == [g.parent.id, g.first.id, g.second.id])
    }

    @Test func aConvertedGroupsHardCloseEndsTheUndoOfCompanionsParkedUnderTheConvertedSession() throws {
        let g = try CompanionGroup()
        #expect(g.store.softCloseSession(g.first.id, grace: 60))
        let fresh = try g.store.convertToCompanion(g.parent.id).get()

        g.store.closeSession(fresh.id)

        #expect(g.store.pendingCloseSession(withID: g.first.id) == nil)
        #expect(!g.store.undoPendingClose())
        #expect(g.store.session(withID: g.first.id) == nil)
    }

    @Test func aSoftClosedConvertedGroupUndoesWhole() throws {
        let g = try CompanionGroup()
        let fresh = try g.store.convertToCompanion(g.parent.id).get()

        #expect(g.store.softCloseSession(fresh.id, grace: 60))
        #expect(g.order == [g.after.id])
        #expect(g.store.undoPendingClose())

        #expect(g.order == [fresh.id, g.parent.id, g.first.id, g.second.id, g.after.id])
        #expect([g.parent, g.first, g.second].allSatisfy { $0.parentID == fresh.id })
    }

    private func addTopLevelPage(to store: AppStore, workspace: Workspace) throws -> Session {
        let page = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/page", content: .page))
        #expect(store.openHtmlOverlay(page.id, pane: nil, overlay: HtmlOverlay(source: .file(path: "/tmp/root.html", grantRoot: nil)),
                                      sizePercent: nil) == nil)
        return page
    }

    @Test func aTopLevelPageGroupsTerminalAndPageCompanions() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let page = try addTopLevelPage(to: store, workspace: workspace)
        let after = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/after"))

        let terminal = try store.addCompanion(to: page.id).get()
        let nested = try store.addPageCompanion(to: page.id, overlay: HtmlOverlay(source: .file(path: "/tmp/n.html", grantRoot: nil))).get()

        #expect(store.workspaces[0].sessions.map(\.id) == [page.id, terminal.id, nested.id, after.id])
        #expect(page.parentID == nil)
        #expect(terminal.content == .terminal)
        #expect(nested.content == .page)
        #expect(store.companions(of: page.id).map(\.id) == [terminal.id, nested.id])
        #expect(store.parent(of: terminal) === page)
        #expect(store.parent(of: nested) === page)
    }

    @Test func aCompanionOfAPageCompanionLandsUnderThePageRoot() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let page = try addTopLevelPage(to: store, workspace: workspace)
        let after = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/after"))
        let nested = try store.addPageCompanion(to: page.id, overlay: HtmlOverlay(source: .file(path: "/tmp/n.html", grantRoot: nil))).get()

        let sibling = try store.addCompanion(to: nested.id).get()

        #expect(sibling.parentID == page.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [page.id, nested.id, sibling.id, after.id])
    }

    @Test func convertNestsATopLevelPageAndItsCompanionsUnderAFreshTerminal() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let before = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/before"))
        let page = try addTopLevelPage(to: store, workspace: workspace)
        let companion = try store.addCompanion(to: page.id, options: CompanionOptions(select: false)).get()
        let overlay = try #require(page.htmlOverlay)

        let fresh = try store.convertToCompanion(page.id).get()

        #expect(store.workspaces[0].sessions.map(\.id) == [before.id, fresh.id, page.id, companion.id])
        #expect(fresh.content == .terminal)
        #expect(fresh.parentID == nil)
        #expect(fresh.initialCwd == "/page")
        #expect(page.parentID == fresh.id)
        #expect(companion.parentID == fresh.id)
        #expect(page.content == .page)
        #expect(page.htmlOverlay?.id == overlay.id)
        #expect(store.selectedSessionID == page.id)
    }

    @Test(arguments: [0, 1, 2])
    func aPageSessionLandsAfterTheAnchorsWholeGroupInItsCwd(anchor: Int) throws {
        let g = try CompanionGroup()
        let overlay = HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))

        let page = try g.store.addPageSession(after: [g.parent, g.first, g.second][anchor].id, overlay: overlay).get()

        #expect(g.order == [g.parent.id, g.first.id, g.second.id, page.id, g.after.id])
        #expect(page.parentID == nil)
        #expect(page.content == .page)
        #expect(page.htmlOverlay?.id == overlay.id)
        #expect(page.initialCwd == ["/parent", "/first", "/second"][anchor])
        #expect(g.store.selectedSessionID == page.id)
    }

    @Test func aPageSessionIsSavedOnCreationAndCreatedUnselectedWhenAsked() throws {
        let (store, _, persistence) = makeStoreWithRecentClosed()
        let workspace = store.addWorkspace(name: "work")
        let anchor = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/anchor"))

        let page = try store.addPageSession(after: anchor.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil)),
                                            select: false, backgroundColor: "#112233").get()

        #expect(store.selectedSessionID == anchor.id)
        #expect(page.overlayBackgroundColor == "#112233")
        let saved = persistence.load().workspaces.flatMap(\.sessions).first { $0.id == page.id }
        #expect(saved?.page == PageSnapshot(source: .file(path: "/tmp/p.html", grantRoot: nil), backgroundColor: "#112233"))
        #expect(saved?.parentID == nil)
    }

    @Test func aRemoteAnchorPlacesALocalPageSessionBesideIt() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/nowhere-on-this-mac", remoteHost: "buildbox"))
        let after = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/after"))

        let page = try store.addPageSession(after: remote.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()

        #expect(store.workspaces[0].sessions.map(\.id) == [remote.id, page.id, after.id])
        #expect(page.remoteHost == nil)
        #expect(page.initialCwd == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func aPageSessionNeedsAnAnchor() {
        let store = makeStore()
        _ = store.addWorkspace(name: "work")

        #expect(refusal(store.addPageSession(after: UUID(), overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil)))) == .noSuchSession)
        #expect(store.workspaces[0].sessions.isEmpty)
    }

    @Test func aRemotePageRowIsRefusedAsAParent() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/r", remoteHost: "buildbox", content: .page))

        #expect(refusal(store.addCompanion(to: remote.id)) == .remoteParent)
        #expect(refusal(store.addPageCompanion(to: remote.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil)))) == .remoteParent)
        #expect(convertRefusal(store.convertToCompanion(remote.id)) == .remoteSession)
        #expect(store.workspaces[0].sessions.map(\.id) == [remote.id])
        #expect(remote.parentID == nil)
    }

    @Test func closingAPageRootClosesItsCompanions() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let page = try addTopLevelPage(to: store, workspace: workspace)
        let after = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/after"))
        let terminal = try store.addCompanion(to: page.id).get()
        let nested = try store.addPageCompanion(to: page.id, overlay: HtmlOverlay(source: .file(path: "/tmp/n.html", grantRoot: nil))).get()

        store.closeSession(page.id)

        #expect(store.workspaces[0].sessions.map(\.id) == [after.id])
        #expect([page.id, terminal.id, nested.id].allSatisfy { store.session(withID: $0) == nil })
    }

    @Test func softClosingAPageRootIsOneUndoForTheWholeGroup() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let page = try addTopLevelPage(to: store, workspace: workspace)
        let after = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/after"))
        let terminal = try store.addCompanion(to: page.id).get()
        let nested = try store.addPageCompanion(to: page.id, overlay: HtmlOverlay(source: .file(path: "/tmp/n.html", grantRoot: nil))).get()
        let overlay = try #require(page.htmlOverlay)

        #expect(store.softCloseSession(page.id, grace: 60))
        #expect(store.workspaces[0].sessions.map(\.id) == [after.id])

        #expect(store.undoPendingClose())
        #expect(store.workspaces[0].sessions.map(\.id) == [page.id, terminal.id, nested.id, after.id])
        #expect(terminal.parentID == page.id)
        #expect(nested.parentID == page.id)
        #expect(page.htmlOverlay?.id == overlay.id)
    }
}

private final class CompanionEventKinds {
    var kinds: [ControlEventKind] = []
}
