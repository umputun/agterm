import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class WorkspaceSidebarCompanionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: RecordingOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var savedUserKeyEquivalents = true

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            savedUserKeyEquivalents = NSMenuItem.usesUserKeyEquivalents
            NSMenuItem.usesUserKeyEquivalents = false
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-companions-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            NSMenuItem.usesUserKeyEquivalents = savedUserKeyEquivalents
            GhosttyApp.shared.setFlaggedViewLayout(.flat)
            GhosttyApp.shared.setAgentStatusColors(activeHex: nil, blockedHex: nil, completedHex: nil)
            window?.orderOut(nil)
            window = nil
            outline = nil
            coordinator = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testCompanionRowsNestUnderTheirParent() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        let parentNode = try node(group.parent.id)
        XCTAssertEqual(parentNode.children.map(\.id), [group.first.id, group.second.id])
        XCTAssertEqual(try node(group.work.id).children.map(\.id), [group.parent.id, group.after.id])
        XCTAssertTrue(outline.isExpandable(parentNode))
        XCTAssertEqual(outline.level(forRow: try row(group.first.id)), outline.level(forRow: try row(group.parent.id)) + 1)
        XCTAssertEqual(try cell(group.first.id).textField?.accessibilityLabel(), "companion")
        XCTAssertNil(try cell(group.parent.id).textField?.accessibilityLabel())
    }

    func testFlaggedLayoutsListCompanionsAtTheirParentsLevel() throws {
        let group = try seed()
        group.store.setFlag(true, forSessions: [group.parent.id, group.first.id])
        group.store.setSidebarMode(.flagged)
        buildSidebar(for: group.store)

        XCTAssertTrue(try node(group.parent.id).children.isEmpty)
        XCTAssertEqual(outline.level(forRow: try row(group.first.id)), outline.level(forRow: try row(group.parent.id)))
    }

    func testFoldingAParentPersistsAndMarksItsCompanionsInTheMostUrgentStatusColor() throws {
        let group = try seed()
        group.store.setAgentIndicator(AgentIndicator(status: .completed), forSession: group.first.id)
        group.store.setAgentIndicator(AgentIndicator(status: .blocked, color: "#123456"), forSession: group.second.id)
        buildSidebar(for: group.store)
        XCTAssertTrue(try marker(group.parent.id).isHidden, "an open parent shows its companions")

        outline.collapseItem(try node(group.parent.id))

        XCTAssertFalse(group.parent.isExpanded)
        let marker = try marker(group.parent.id)
        XCTAssertFalse(marker.isHidden)
        XCTAssertEqual(marker.contentTintColor, NSColor(agtermHex: "#123456"))
        XCTAssertEqual(marker.accessibilityLabel(), "companions: second blocked, first completed")

        outline.expandItem(try node(group.parent.id))

        XCTAssertTrue(group.parent.isExpanded)
        XCTAssertTrue(try self.marker(group.parent.id).isHidden)
    }

    func testAFoldedParentRetintsWhenAHiddenCompanionChangesStatus() throws {
        let group = try seed()
        group.store.setSessionExpanded(group.parent.id, expanded: false)
        group.first.unseenCount = 2
        buildSidebar(for: group.store)
        XCTAssertTrue(try marker(group.parent.id).isHidden, "unread notifications alone leave no marker")

        group.store.setAgentIndicator(AgentIndicator(status: .active), forSession: group.first.id)
        coordinator.reconcile()
        XCTAssertFalse(try marker(group.parent.id).isHidden)
        XCTAssertEqual(try marker(group.parent.id).contentTintColor, GhosttyApp.shared.statusColor(for: .active))
        XCTAssertEqual(try marker(group.parent.id).accessibilityLabel(), "companions: first active")

        group.store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: group.second.id)
        coordinator.reconcile()
        XCTAssertEqual(try marker(group.parent.id).contentTintColor, GhosttyApp.shared.statusColor(for: .blocked))
        XCTAssertEqual(try marker(group.parent.id).accessibilityLabel(), "companions: second blocked, first active")
    }

    func testAStatusColorChangeInSettingsRetintsAFoldedParentsMarker() throws {
        let group = try seed()
        group.store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: group.first.id)
        group.store.setSessionExpanded(group.parent.id, expanded: false)
        group.store.selectSession(group.after.id)
        buildSidebar(for: group.store)

        GhosttyApp.shared.setAgentStatusColors(activeHex: nil, blockedHex: "#abcdef", completedHex: nil)
        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)

        XCTAssertFalse(try marker(group.parent.id).isHidden)
        XCTAssertEqual(try marker(group.parent.id).contentTintColor, NSColor(agtermHex: "#abcdef"))
    }

    func testAFoldedParentStaysFoldedAcrossARebuild() throws {
        let group = try seed()
        group.store.setSessionExpanded(group.parent.id, expanded: false)
        buildSidebar(for: group.store)

        XCTAssertFalse(outline.isItemExpanded(try node(group.parent.id)))
        coordinator.rebuildAndReload()
        XCTAssertFalse(outline.isItemExpanded(try node(group.parent.id)))
    }

    func testSelectingACompanionOfAFoldedParentRevealsItWithoutPersisting() throws {
        let group = try seed()
        group.store.setSessionExpanded(group.parent.id, expanded: false)
        group.store.setWorkspaceExpanded(group.work.id, expanded: false)
        buildSidebar(for: group.store)

        group.store.selectSession(group.second.id)
        coordinator.syncSelection()

        XCTAssertEqual(outline.selectedRow, try row(group.second.id))
        XCTAssertFalse(group.parent.isExpanded, "a reveal is a view action")
        XCTAssertEqual(group.store.selectedSessionID, group.second.id)
    }

    func testFoldingAParentKeepsTheActiveCompanion() throws {
        let group = try seed()
        buildSidebar(for: group.store)
        group.store.selectSession(group.first.id)
        coordinator.syncSelection()

        outline.collapseItem(try node(group.parent.id))

        XCTAssertEqual(group.store.selectedSessionID, group.first.id)
    }

    func testRowMenuNewCompanionAddsASiblingUnderTheParent() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        let menu = try XCTUnwrap(coordinator.menu(forRow: try row(group.first.id)))
        let item = try XCTUnwrap(menu.items.first { $0.title == "New Companion" }, "menu had \(menu.items.map(\.title))")
        coordinator.perform(item.action, with: item)

        let companions = group.store.companions(of: group.parent.id)
        XCTAssertEqual(companions.count, 3)
        XCTAssertEqual(group.store.selectedSessionID, companions.last?.id)
    }

    func testRowMenuConvertToCompanionNestsTheRowUnderAFreshParent() throws {
        let group = try seed()
        buildSidebar(for: group.store)
        group.store.setSidebarSelection([group.after.id])

        let menu = try XCTUnwrap(coordinator.menu(forRow: try row(group.after.id)))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Convert to Companion" }, "menu had \(menu.items.map(\.title))")
        XCTAssertTrue(item.isEnabled)
        coordinator.perform(item.action, with: item)

        let parent = try XCTUnwrap(group.store.parent(of: group.after))
        XCTAssertNil(parent.parentID)
        XCTAssertEqual(group.store.selectedSessionID, group.after.id)
    }

    func testCompanionItemsSitInTheirOwnSectionOnParentAndCompanionRows() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        for (id, last) in [(group.after.id, "Convert to Companion"), (group.first.id, "Duplicate as Companion")] {
            group.store.setSidebarSelection([id])
            let items = try XCTUnwrap(coordinator.menu(forRow: try row(id))).items
            let first = try XCTUnwrap(items.firstIndex { $0.title == "New Companion" }, "\(items.map(\.title))")
            let end = try XCTUnwrap(items.firstIndex { $0.title == last }, "\(items.map(\.title))")
            XCTAssertTrue(items[first - 1].isSeparatorItem, "\(items.map(\.title))")
            XCTAssertTrue(items[end + 1].isSeparatorItem, "\(items.map(\.title))")
        }
    }

    func testConvertIsOmittedOnACompanionRowAndEnabledOnARowAttachedFromAnotherHost() throws {
        let group = try seed()
        let remote = try XCTUnwrap(group.store.addSession(toWorkspace: group.work.id, cwd: "/tmp", remoteHost: "far"))
        buildSidebar(for: group.store)

        let companionMenu = try XCTUnwrap(coordinator.menu(forRow: try row(group.first.id)))
        XCTAssertNil(companionMenu.items.first { $0.title == "Convert to Companion" }, "\(companionMenu.items.map(\.title))")
        group.store.setSidebarSelection([remote.id])
        let remoteMenu = try XCTUnwrap(coordinator.menu(forRow: try row(remote.id)))
        let item = try XCTUnwrap(remoteMenu.items.first { $0.title == "Convert to Companion" }, "\(remoteMenu.items.map(\.title))")
        XCTAssertTrue(item.isEnabled)
    }

    // a cached parent node kept its nested rows into the flat flagged list
    func testSwitchingToAFlatFlaggedLayoutDropsTheParentsNestedRows() throws {
        let group = try seed()
        group.store.setFlag(true, forSession: group.parent.id)
        buildSidebar(for: group.store)
        XCTAssertFalse(try node(group.parent.id).children.isEmpty)

        for layout in [FlaggedViewLayout.flat, .plain] {
            GhosttyApp.shared.setFlaggedViewLayout(layout)
            group.store.setSidebarMode(.flagged)
            coordinator.reconcile()

            XCTAssertTrue(try node(group.parent.id).children.isEmpty, "\(layout)")
            XCTAssertFalse(outline.isExpandable(try node(group.parent.id)), "\(layout)")
            XCTAssertEqual(outline.numberOfRows, 1, "\(layout)")
            group.store.setSidebarMode(.tree)
            coordinator.reconcile()
        }
    }

    // an on-row drop was retargeted to a flat workspace index that acceptDrop could not read back
    func testASiblingDroppedOnItsSiblingRowReordersTheGroup() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.first.id], onRow: group.second.id))

        XCTAssertEqual(group.store.workspaces.first { $0.id == group.work.id }?.sessions.map(\.id),
                       [group.parent.id, group.second.id, group.first.id, group.after.id])
    }

    func testATopLevelSessionDroppedInTheGapBelowARowLandsRightAfterThatRow() throws {
        let group = try seed()
        let middle = try XCTUnwrap(group.store.addSession(toWorkspace: group.work.id, cwd: "/tmp", name: "middle"))
        let last = try XCTUnwrap(group.store.addSession(toWorkspace: group.work.id, cwd: "/tmp", name: "last"))
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([last.id], onto: group.work.id, childIndex: 2))
        XCTAssertNil(last.parentID)

        XCTAssertEqual(group.store.workspaces.first { $0.id == group.work.id }?.sessions.map(\.id),
                       [group.parent.id, group.first.id, group.second.id, group.after.id, last.id, middle.id])
    }

    func testATopLevelSessionDroppedOnAnotherTopLevelRowBecomesItsFirstCompanionWithItsGroup() throws {
        let group = try seed()
        let resident = try group.store.addCompanion(to: group.after.id, options: CompanionOptions(name: "resident")).get()
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.parent.id], onRow: group.after.id))

        XCTAssertEqual(group.store.companions(of: group.after.id).map(\.id),
                       [group.parent.id, group.first.id, group.second.id, resident.id])
        for moved in [group.parent, group.first, group.second] {
            XCTAssertEqual(moved.parentID, group.after.id)
            XCTAssertTrue(group.store.session(withID: moved.id) === moved)
        }
    }

    func testARefusedTopLevelNestLeavesTheTreeInsteadOfReordering() throws {
        let group = try seed()
        let remote = try XCTUnwrap(group.store.addSession(toWorkspace: group.work.id, cwd: "/tmp", name: "remote", remoteHost: "buildbox"))
        buildSidebar(for: group.store)
        let before = group.store.workspaces.first { $0.id == group.work.id }?.sessions.map(\.id)

        XCTAssertFalse(try drop([group.after.id], onRow: remote.id))

        XCTAssertEqual(group.store.workspaces.first { $0.id == group.work.id }?.sessions.map(\.id), before)
        XCTAssertNil(group.after.parentID)
    }

    func testATopLevelSessionKeepsItsParentlessPlaceOutsideATopLevelRowsCenter() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        _ = try drop([group.after.id], onto: group.parent.id, childIndex: 1)
        XCTAssertNil(group.after.parentID)
        _ = try drop([group.after.id], onRow: group.first.id)
        XCTAssertNil(group.after.parentID)
    }

    func testSeveralTopLevelRowsDroppedOnARowStillReorder() throws {
        let group = try seed()
        let last = try XCTUnwrap(group.store.addSession(toWorkspace: group.work.id, cwd: "/tmp", name: "last"))
        let extra = try XCTUnwrap(group.store.addSession(toWorkspace: group.work.id, cwd: "/tmp", name: "extra"))
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.after.id, extra.id], onRow: last.id))

        XCTAssertEqual(group.store.workspaces.first { $0.id == group.work.id }?.sessions.map(\.id),
                       [group.parent.id, group.first.id, group.second.id, last.id, group.after.id, extra.id])
        XCTAssertNil(group.after.parentID)
        XCTAssertNil(extra.parentID)
    }

    func testACompanionDroppedOnItsOwnParentRowMovesFirstInTheGroup() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.second.id], onRow: group.parent.id))

        XCTAssertEqual(group.store.companions(of: group.parent.id).map(\.id), [group.second.id, group.first.id])
    }

    func testAParentDraggedWithItsCompanionMovesTheGroupToAnotherWorkspace() throws {
        let group = try seed()
        let other = group.store.addWorkspace(name: "other")
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.parent.id, group.first.id], onRow: other.id))

        XCTAssertEqual(group.store.workspaces.first { $0.id == other.id }?.sessions.map(\.id),
                       [group.parent.id, group.first.id, group.second.id])
    }

    func testMoveUnderListsOtherParentsForACompanionAndIsAbsentForAParent() throws {
        let group = try seed()
        let other = group.store.addWorkspace(name: "other")
        let elsewhere = try XCTUnwrap(group.store.addSession(toWorkspace: other.id, cwd: "/tmp", name: "elsewhere", select: false))
        buildSidebar(for: group.store)

        let parentMenu = try XCTUnwrap(coordinator.menu(forRow: try row(group.parent.id)))
        XCTAssertNotNil(parentMenu.items.first { $0.title == "Move to" })
        XCTAssertNil(parentMenu.items.first { $0.title == "Move Under" })
        group.store.setSidebarSelection([group.first.id])
        let companionMenu = try XCTUnwrap(coordinator.menu(forRow: try row(group.first.id)))
        let submenu = try XCTUnwrap(companionMenu.items.first { $0.title == "Move Under" }?.submenu, "\(companionMenu.items.map(\.title))")
        let titles = submenu.items.map(\.title)
        XCTAssertEqual(Array(titles.suffix(4)), ["work", "after", "other", "elsewhere"], "\(titles)")
        XCTAssertFalse(titles.contains("parent"), "the current parent is no destination")
        XCTAssertEqual(submenu.items.suffix(4).map(\.isSectionHeader), [true, false, true, false])

        let item = try XCTUnwrap(submenu.items.first { $0.title == "elsewhere" })
        coordinator.perform(item.action, with: item)

        XCTAssertEqual(group.first.parentID, elsewhere.id)
        XCTAssertEqual(group.store.workspaces.first { $0.id == other.id }?.sessions.map(\.id), [elsewhere.id, group.first.id])
    }

    func testACompanionDroppedOnAnotherTopLevelRowBecomesItsFirstCompanion() throws {
        let group = try seed()
        let resident = try group.store.addCompanion(to: group.after.id, options: CompanionOptions(name: "resident")).get()
        group.store.setSessionExpanded(group.after.id, expanded: false)
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.second.id], onto: group.after.id))

        XCTAssertEqual(group.second.parentID, group.after.id)
        XCTAssertEqual(group.store.workspaces.first { $0.id == group.work.id }?.sessions.map(\.id),
                       [group.parent.id, group.first.id, group.after.id, group.second.id, resident.id])
    }

    func testACompanionDroppedInAGapOrOnARowOfAnotherGroupLandsWhereTheIndicatorShows() throws {
        let group = try seed()
        let resident = try group.store.addCompanion(to: group.after.id, options: CompanionOptions(name: "resident")).get()
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.second.id], onto: group.after.id, childIndex: 1))
        XCTAssertEqual(group.store.companions(of: group.after.id).map(\.id), [resident.id, group.second.id])

        coordinator.rebuildAndReload()
        XCTAssertTrue(try drop([group.first.id], onto: resident.id))
        XCTAssertEqual(group.store.companions(of: group.after.id).map(\.id), [resident.id, group.first.id, group.second.id])
        XCTAssertTrue(group.store.companions(of: group.parent.id).isEmpty)
    }

    func testSeveralCompanionsCannotChangeParentOrLeaveTheirGroupTogether() throws {
        let group = try seed()
        buildSidebar(for: group.store)

        XCTAssertFalse(try drop([group.first.id, group.second.id], onto: group.work.id, childIndex: 1))
        XCTAssertFalse(try drop([group.first.id, group.second.id], onto: group.after.id))
        XCTAssertEqual(group.store.companions(of: group.parent.id).map(\.id), [group.first.id, group.second.id])
    }

    func testACompanionDroppedInATopLevelGapOrOnAWorkspaceRowBecomesTopLevelThere() throws {
        let group = try seed()
        let other = group.store.addWorkspace(name: "other")
        let resident = try XCTUnwrap(group.store.addSession(toWorkspace: other.id, cwd: "/tmp", name: "resident", select: false))
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.first.id], onto: group.work.id, childIndex: 1))
        XCTAssertNil(group.first.parentID)
        XCTAssertEqual(group.store.workspaces.first { $0.id == group.work.id }?.sessions.map(\.id),
                       [group.parent.id, group.second.id, group.first.id, group.after.id])

        coordinator.rebuildAndReload()
        XCTAssertTrue(try drop([group.second.id], onRow: other.id))
        XCTAssertNil(group.second.parentID)
        XCTAssertEqual(group.store.workspaces.first { $0.id == other.id }?.sessions.map(\.id), [resident.id, group.second.id])
    }

    func testACompanionDroppedInTheTopLevelGapBecomesATopLevelSessionThere() throws {
        let group = try seed()
        let root = try XCTUnwrap(group.store.rootWorkspace)
        let top = try XCTUnwrap(group.store.addSession(toWorkspace: root.id, cwd: "/tmp", name: "top", select: false))
        buildSidebar(for: group.store)

        XCTAssertTrue(try drop([group.first.id], item: nil, childIndex: 0))

        XCTAssertNil(group.first.parentID)
        XCTAssertEqual(group.store.rootWorkspace?.sessions.map(\.id), [group.first.id, top.id])
    }

    func testMoveToOnACompanionListsEveryWorkspaceAndMakesItTopLevelThere() throws {
        let group = try seed()
        let other = group.store.addWorkspace(name: "other")
        buildSidebar(for: group.store)
        group.store.setSidebarSelection([group.first.id])

        let menu = try XCTUnwrap(coordinator.menu(forRow: try row(group.first.id)))
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "Move to" }?.submenu, "\(menu.items.map(\.title))")
        let labels = group.store.displayWorkspaces.map(\.label)
        XCTAssertEqual(submenu.items.map(\.title), labels)
        XCTAssertTrue(labels.contains("work"), "\(labels)")

        let item = try XCTUnwrap(submenu.items.first { $0.title == "other" })
        coordinator.perform(item.action, with: item)

        XCTAssertNil(group.first.parentID)
        XCTAssertEqual(group.store.workspaces.first { $0.id == other.id }?.sessions.map(\.id), [group.first.id])
    }

    func testTheFlaggedTreeKeepsCompanionsAmongTheirSiblings() throws {
        let group = try seed()
        GhosttyApp.shared.setFlaggedViewLayout(.tree)
        group.store.setFlag(true, forSessions: [group.parent.id, group.first.id, group.second.id, group.after.id])
        group.store.setSidebarMode(.flagged)
        buildSidebar(for: group.store)

        _ = try drop([group.first.id], onto: group.after.id)

        XCTAssertEqual(group.first.parentID, group.parent.id)
    }

    func testASelectedCompanionMovedUnderAFoldedParentIsRevealedWithoutPersisting() throws {
        let group = try seed()
        _ = try group.store.addCompanion(to: group.after.id, options: CompanionOptions(name: "resident")).get()
        group.store.setSessionExpanded(group.after.id, expanded: false)
        group.store.selectSession(group.first.id)
        buildSidebar(for: group.store)
        coordinator.syncSelection()

        XCTAssertNoThrow(try group.store.moveCompanion(group.first.id, under: group.after.id).get())
        coordinator.rebuildAndReload()
        coordinator.syncSelection()

        XCTAssertEqual(outline.selectedRow, try row(group.first.id))
        XCTAssertFalse(group.after.isExpanded, "a reveal is a view action")
    }

    private func drop(_ ids: [UUID], onRow target: UUID) throws -> Bool {
        try drop(ids, onto: target)
    }

    private func drop(_ ids: [UUID], onto target: UUID, childIndex: Int = SidebarDrop.onItemIndex) throws -> Bool {
        try drop(ids, item: try node(target), childIndex: childIndex)
    }

    private func drop(_ ids: [UUID], item: SidebarNode?, childIndex: Int) throws -> Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agterm-companions-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(ids.map(\.uuidString).joined(separator: "\n"), forType: sessionPasteboardType)
        let info = SidebarDrag(pasteboard, over: outline)
        let operation = coordinator.outlineView(outline, validateDrop: info, proposedItem: item, proposedChildIndex: childIndex)
        guard operation == .move else { return false }
        return coordinator.outlineView(outline, acceptDrop: info, item: outline.dropItem,
                                       childIndex: outline.dropChildIndex)
    }

    func testAPageCompanionRowShowsThePageIconFilledWhenFlagged() throws {
        let group = try seed()
        let page = try group.store.addPageCompanion(to: group.parent.id,
                                                    overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil)),
                                                    select: false).get()
        buildSidebar(for: group.store)
        XCTAssertTrue(try cell(page.id).imageView?.image === coordinator.pageSessionIcon)

        group.store.setFlag(true, forSession: page.id)
        coordinator.reconcile()

        XCTAssertTrue(try cell(page.id).imageView?.image === coordinator.flaggedPageSessionIcon)
    }

    func testRowMenuConvertToCompanionNestsATopLevelPageUnderAFreshParent() throws {
        let group = try seed()
        let page = try addTopLevelPage(to: group)
        buildSidebar(for: group.store)
        group.store.setSidebarSelection([page.id])

        let menu = try XCTUnwrap(coordinator.menu(forRow: try row(page.id)))
        XCTAssertNil(menu.items.first { $0.title == "Duplicate as Companion" }, "\(menu.items.map(\.title))")
        let item = try XCTUnwrap(menu.items.first { $0.title == "Convert to Companion" }, "\(menu.items.map(\.title))")
        XCTAssertTrue(item.isEnabled)
        coordinator.perform(item.action, with: item)

        let parent = try XCTUnwrap(group.store.parent(of: page))
        XCTAssertNil(parent.parentID)
        XCTAssertEqual(parent.content, .terminal)
        XCTAssertEqual(group.store.selectedSessionID, page.id)
    }

    func testRowMenuNewCompanionOnAPageCompanionLandsUnderItsPageRoot() throws {
        let group = try seed()
        let page = try addTopLevelPage(to: group)
        let nested = try group.store.addPageCompanion(to: page.id,
                                                      overlay: HtmlOverlay(source: .file(path: "/tmp/n.html", grantRoot: nil)),
                                                      select: false).get()
        buildSidebar(for: group.store)
        XCTAssertEqual(try node(page.id).children.map(\.id), [nested.id])

        let menu = try XCTUnwrap(coordinator.menu(forRow: try row(nested.id)))
        let item = try XCTUnwrap(menu.items.first { $0.title == "New Companion" }, "\(menu.items.map(\.title))")
        coordinator.perform(item.action, with: item)

        let companions = group.store.companions(of: page.id)
        XCTAssertEqual(companions.count, 2)
        XCTAssertEqual(companions.first?.id, nested.id)
        XCTAssertEqual(companions.last?.content, .terminal)
        XCTAssertEqual(group.store.selectedSessionID, companions.last?.id)
    }

    private func addTopLevelPage(to group: CompanionRows) throws -> Session {
        let page = try XCTUnwrap(group.store.addSession(toWorkspace: group.work.id, cwd: "/tmp", select: false, content: .page))
        XCTAssertNil(group.store.openHtmlOverlay(page.id, pane: nil, overlay: HtmlOverlay(source: .file(path: "/tmp/root.html", grantRoot: nil)),
                                                 sizePercent: nil))
        return page
    }

    private func seed() throws -> CompanionRows {
        let store = try XCTUnwrap(library.activeStore)
        let work = store.addWorkspace(name: "work")
        let parent = try XCTUnwrap(store.addSession(toWorkspace: work.id, cwd: "/tmp", name: "parent"))
        let after = try XCTUnwrap(store.addSession(toWorkspace: work.id, cwd: "/tmp", name: "after"))
        let first = try store.addCompanion(to: parent.id, options: CompanionOptions(name: "first")).get()
        let second = try store.addCompanion(to: parent.id, options: CompanionOptions(name: "second")).get()
        return CompanionRows(store: store, work: work, parent: parent, first: first, second: second, after: after)
    }

    private func node(_ id: UUID) throws -> SidebarNode {
        try XCTUnwrap(outline.item(atRow: try row(id)) as? SidebarNode)
    }

    private func row(_ id: UUID) throws -> Int {
        try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == id },
                      "no visible row for \(id)")
    }

    private func cell(_ id: UUID) throws -> SidebarCellView {
        try XCTUnwrap(outline.view(atColumn: 0, row: try row(id), makeIfNecessary: true) as? SidebarCellView)
    }

    private func marker(_ id: UUID) throws -> NSImageView {
        try XCTUnwrap(try cell(id).companionMarker)
    }

    private func buildSidebar(for store: AppStore) {
        outline = RecordingOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        scroll.documentView = outline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.rebuildAndReload()
    }
}

private struct CompanionRows {
    let store: AppStore
    let work: Workspace
    let parent: Session
    let first: Session
    let second: Session
    let after: Session
}

final class RecordingOutlineView: NSOutlineView {
    private(set) var dropItem: Any?
    private(set) var dropChildIndex = SidebarDrop.onItemIndex

    override func setDropItem(_ item: Any?, dropChildIndex index: Int) {
        dropItem = item
        dropChildIndex = index
        super.setDropItem(item, dropChildIndex: index)
    }
}

@MainActor
final class SidebarDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint

    init(_ pasteboard: NSPasteboard, over view: NSView, at location: NSPoint = .zero) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = view.window
        draggingLocation = location
    }

    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to _: NSPoint) {}
    func enumerateDraggingItems(options _: NSDraggingItemEnumerationOptions = [], for _: NSView?, classes _: [AnyClass],
                                searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
