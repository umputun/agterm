import Foundation
import Testing
@testable import agtermCore

// `AppStore.controlTree()` projection coverage: the session/workspace node shape and every field the tree
// reports. Split out of `AppStoreTests.swift` for the file size limit.
@MainActor
struct AppStoreTreeProjectionTests {
    @Test func controlTreeProjectsWorkspaceAndSessionShape() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = try #require(store.addSession(toWorkspace: work.id, cwd: "/repo/a", name: "alpha"))
        let b = try #require(store.addSession(toWorkspace: personal.id, cwd: "/repo/b"))
        b.currentCwd = "/live/b"
        b.oscTitle = "remote:~/b"
        b.isSplit = true
        b.hasSplit = true
        b.splitSurface = SpySurface() // a live split pane, so the `.right` status below stays valid
        b.overlayActive = true
        b.scratchActive = true
        b.flagged = true
        b.backgroundWatermark = BackgroundWatermark(kind: .text, text: "PROD")
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: b.id)
        b.statusChangedAt = Date(timeIntervalSince1970: 1_700_000_000) // wall-clock stamp, pinned to compare
        store.selectSession(b.id)

        let tree = store.controlTree()

        #expect(tree.workspaces.map(\.id) == [work.id.uuidString, personal.id.uuidString])
        #expect(tree.workspaces.map(\.name) == ["work", "personal"])
        #expect(tree.workspaces.map(\.active) == [false, true])
        #expect(tree.workspaces[0].sessions == [
            ControlSessionNode(id: a.id.uuidString, name: "alpha", cwd: "/repo/a",
                               active: false, split: false,
                               backedByZmx: false,
                               surfaces: [
                                ControlSurfaceNode(id: TerminalSurfaceID(sessionID: a.id, surface: .primary).rawValue,
                                                   kind: "left", active: true, visible: true,
                                                   backedByZmx: false),
                               ],
                               // store-only session: a surface slot with nothing in it has no terminal
                               realized: false)
        ])
        #expect(tree.workspaces[1].sessions == [
            ControlSessionNode(id: b.id.uuidString, name: "remote:~/b", cwd: "/live/b",
                               title: "remote:~/b", active: true, split: true,
                               hasSplit: true, backedByZmx: false,
                               splitAxis: "vertical", splitFocused: false,
                               overlay: true, scratch: true, flagged: true,
                               status: "blocked", statusPane: "right", statusChangedAt: 1_700_000_000,
                               background: BackgroundWatermark(kind: .text, text: "PROD"),
                               surfaces: [
                                ControlSurfaceNode(id: TerminalSurfaceID(sessionID: b.id, surface: .primary).rawValue,
                                                   kind: "left", active: false, visible: false,
                                                   backedByZmx: false),
                                ControlSurfaceNode(id: TerminalSurfaceID(sessionID: b.id, surface: .split).rawValue,
                                                   kind: "right", active: false, visible: false,
                                                   backedByZmx: false),
                                ControlSurfaceNode(id: TerminalSurfaceID(sessionID: b.id, surface: .scratch).rawValue,
                                                   kind: "scratch", active: false, visible: false),
                                ControlSurfaceNode(id: TerminalSurfaceID(sessionID: b.id, surface: .overlay).rawValue,
                                                   kind: "overlay", active: true, visible: true),
                               ],
                               realized: false)
        ])
    }

    @Test func controlTreeProjectsSessionContext() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let withContext = try #require(store.addSession(toWorkspace: work.id, cwd: "/repo/a"))
        let without = try #require(store.addSession(toWorkspace: work.id, cwd: "/repo/b"))
        withContext.context = "PR #517: restore reap ordering"

        let sessions = store.controlTree().workspaces[0].sessions

        #expect(sessions[0].context == "PR #517: restore reap ordering")
        #expect(sessions[1].context == nil)
        #expect(without.context == nil)
    }

    @Test func sessionContextIsOmittedFromJSONWhenUnset() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/repo/a"))

        let bare = try String(decoding: JSONEncoder().encode(store.controlTree()), as: UTF8.self)
        #expect(!bare.contains("\"context\""))

        session.context = "PR #517"
        let set = try String(decoding: JSONEncoder().encode(store.controlTree()), as: UTF8.self)
        #expect(set.contains("\"context\":\"PR #517\""))
    }

    @Test func controlTreeReportsSidebarVisibility() {
        let store = makeStore()
        #expect(store.controlTree().sidebarVisible == true)
        store.setSidebarVisible(false)
        #expect(store.controlTree().sidebarVisible == false)
        store.setSidebarVisible(true)
        #expect(store.controlTree().sidebarVisible == true)
    }

    @Test func controlTreeReportsCollapsedWorkspace() {
        let store = makeStore()
        let ws2 = store.addWorkspace(name: "second")
        #expect(store.controlTree().workspaces.allSatisfy { $0.collapsed == nil })
        store.setWorkspaceExpanded(ws2.id, expanded: false)
        let nodes = store.controlTree().workspaces
        #expect(nodes.first { $0.id == ws2.id.uuidString }?.collapsed == true)
        #expect(nodes.filter { $0.collapsed == true }.count == 1)
        store.setWorkspaceExpanded(ws2.id, expanded: true)
        #expect(store.controlTree().workspaces.allSatisfy { $0.collapsed == nil })
    }

    @Test func controlTreeCollapsedIsIdempotentAndFocusIndependent() {
        let store = makeStore()
        let ws2 = store.addWorkspace(name: "second")
        store.setWorkspaceExpanded(ws2.id, expanded: false)
        store.setWorkspaceExpanded(ws2.id, expanded: false)
        let afterTwice = store.controlTree().workspaces
        #expect(afterTwice.filter { $0.collapsed == true }.count == 1)
        #expect(afterTwice.first { $0.id == ws2.id.uuidString }?.collapsed == true)
        // focus-independent: focusing the collapsed workspace force-reveals it in the sidebar but must NOT
        // flip the persisted model, so the `collapsed` read-back still reports true.
        store.setFocusedWorkspace(ws2.id)
        let focused = store.controlTree().workspaces.first { $0.id == ws2.id.uuidString }
        #expect(focused?.collapsed == true)
        #expect(focused?.focused == true)
    }

    @Test func controlTreeReportsSidebarMode() {
        let store = makeStore()
        #expect(store.controlTree().sidebarMode == "tree")
        store.setSidebarMode(.flagged)
        #expect(store.controlTree().sidebarMode == "flagged")
        store.setSidebarMode(.tree)
        #expect(store.controlTree().sidebarMode == "tree")
    }

    @Test func controlTreeReportsQuickVisibleFromClosure() {
        let store = makeStore()
        #expect(store.controlTree().quickVisible == nil)
        // the app supplies the live QuickTerminalController.isVisible via the closure.
        #expect(store.controlTree(quickVisible: { true }).quickVisible == true)
        #expect(store.controlTree(quickVisible: { false }).quickVisible == false)
    }

    @Test func controlTreeReportsZoomedSurfaceFromClosure() {
        let store = makeStore()
        #expect(store.controlTree().zoomedSurface == nil)
        #expect(store.controlTree(zoomedSurface: { nil }).zoomedSurface == nil)
        // the app supplies the live TerminalZoomController.target?.controlID via the closure.
        let id = "surface:\(UUID().uuidString):left"
        #expect(store.controlTree(zoomedSurface: { id }).zoomedSurface == id)
        #expect(store.controlTree(zoomedSurface: { "quick" }).zoomedSurface == "quick")
    }

    @Test func controlTreeReportsPickPendingFromClosure() {
        let store = makeStore()
        #expect(store.controlTree(pickPending: { "pick-42" }).pickPending == "pick-42")
    }

    @Test func controlTreeOmitsPickPendingWithoutClosure() {
        let store = makeStore()
        #expect(store.controlTree().pickPending == nil)
        #expect(store.controlTree(pickPending: { nil }).pickPending == nil)
    }

    @Test func controlTreeReportsDashboardFieldsFromClosures() {
        let store = makeStore()
        let bare = store.controlTree()
        #expect(bare.dashboardMembers == nil)
        #expect(bare.dashboardHighlighted == nil)
        #expect(bare.dashboardFontSize == nil)
        #expect(bare.dashboardFontMode == nil)
        // members are pane refs (`<uuid>:left`/`:right`), so a split session shows as two cells
        let members = ["9f3c:left", "9f3c:right", "abcd:left"]
        let tree = store.controlTree(dashboardMembers: { members }, dashboardHighlighted: { "9f3c:right" },
                                     dashboardFontSize: { 12 }, dashboardFontMode: { "auto" })
        #expect(tree.dashboardMembers == members)
        #expect(tree.dashboardHighlighted == "9f3c:right")
        #expect(tree.dashboardFontSize == 12)
        #expect(tree.dashboardFontMode == "auto")
    }

    @Test func controlTreeDashboardMembersClosurePassesThroughVerbatim() {
        // an EMPTY array is distinct from nil (omitted). The app side never emits [], so this pins a
        // boundary nothing else reaches.
        let store = makeStore()
        #expect(store.controlTree(dashboardMembers: { [] }).dashboardMembers == [])
        #expect(store.controlTree(dashboardMembers: { nil }).dashboardMembers == nil)
    }

    @Test func setSidebarVisiblePostsChangeNotificationOnlyOnChange() {
        // the app-target ControlServer observes this to refresh window.list's cached sidebarVisible; the
        // post must fire only on an actual change (queue nil so the synchronous post delivers inline).
        final class Counter: @unchecked Sendable { var n = 0 }
        let store = makeStore() // default sidebarVisible == true
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(forName: .agtermSidebarVisibilityChanged, object: nil,
                                                           queue: nil) { _ in counter.n += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.setSidebarVisible(true)
        #expect(counter.n == 0)
        store.setSidebarVisible(false)
        #expect(counter.n == 1)
        store.setSidebarVisible(false)
        #expect(counter.n == 1)
        store.setSidebarVisible(true)
        #expect(counter.n == 2)
    }

    @Test func controlTreeReportsUnseenCountWhenPositive() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        session.unseenCount = 4

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.unseen == 4)
    }

    @Test func controlTreeOmitsUnseenCountWhenZero() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        session.unseenCount = 0

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.unseen == nil) // zero reads as "no badge", omitted from the wire
    }

    @Test func controlTreeReportsStatusPaneForNonIdleSession() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        session.hasSplit = true
        session.splitSurface = SpySurface() // a live split, so a `.right` status is valid (not coerced to `.left`)
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.status == "blocked")
        #expect(node.statusPane == "right")
    }

    @Test func controlTreeNilsStatusPaneWhenIdleEvenWithPane() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.setAgentIndicator(AgentIndicator(status: .idle, statusPane: .right), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.status == nil)
        #expect(node.statusPane == nil)
    }

    @Test func controlTreeOmitsStatusPaneWhenNonIdleButUnspecified() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.status == "completed")
        #expect(node.statusPane == nil)
    }

    @Test func controlTreeReportsStatusShapeOnlyForAPerCallOverride() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let shaped = try #require(store.addSession(toWorkspace: ws.id, cwd: "/shaped"))
        let plain = try #require(store.addSession(toWorkspace: ws.id, cwd: "/plain"))
        store.setAgentIndicator(AgentIndicator(status: .blocked, shape: .triangle), forSession: shaped.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: plain.id)

        let sessions = store.controlTree().workspaces[0].sessions

        #expect(sessions[0].statusShape == "triangle")
        #expect(sessions[1].statusShape == nil) // no per-call shape: the Settings shape / default is not reported
    }

    @Test func controlTreeDropsStatusShapeOnTheNextSetWithoutOne() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        // each session.status builds a whole new indicator, so a following set with no shape replaces it
        store.setAgentIndicator(AgentIndicator(status: .blocked, shape: .triangle), forSession: session.id)
        #expect(store.controlTree().workspaces[0].sessions[0].statusShape == "triangle")

        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: session.id)

        #expect(store.controlTree().workspaces[0].sessions[0].statusShape == nil)
        #expect(store.controlTree().workspaces[0].sessions[0].status == "blocked")
    }

    @Test func controlTreeNilsStatusShapeWhenIdleEvenWithShape() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        // idle renders no glyph, so a retained shape must not project — mirroring statusPane/statusColor
        store.setAgentIndicator(AgentIndicator(status: .idle, shape: .star), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.status == nil)
        #expect(node.statusShape == nil)
    }

    @Test func controlTreeUsesForegroundLookups() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let active = try #require(store.addSession(toWorkspace: ws.id, cwd: "/active"))
        let other = try #require(store.addSession(toWorkspace: ws.id, cwd: "/other"))
        store.selectSession(active.id)

        let tree = store.controlTree(
            foreground: { session in session.id == active.id ? ["ssh", "host"] : nil },
            splitForeground: { session in session.id == other.id ? ["tail", "-f", "app.log"] : nil }
        )

        #expect(tree.workspaces[0].sessions[0].foreground == ["ssh", "host"])
        #expect(tree.workspaces[0].sessions[0].splitForeground == nil)
        #expect(tree.workspaces[0].sessions[1].foreground == nil)
        #expect(tree.workspaces[0].sessions[1].splitForeground == ["tail", "-f", "app.log"])
    }
}
