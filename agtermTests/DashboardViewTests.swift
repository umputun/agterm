import AppKit
import SwiftUI
import XCTest
@testable import agterm
@testable import agtermCore

/// The dashboard host moves its members' queued panes to the front of a paced launch without releasing
/// any: the grid fills at the paced rate, in cell order, instead of in one burst.
@MainActor
final class DashboardViewTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-dashboard-view-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testOpeningOnQueuedMembersPromotesThemButKeepsTheRate() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let sessions = try (0..<3).map { _ in
            try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        }
        let interval = Duration.milliseconds(120)
        var clock = ContinuousClock().now
        var wakes: [@MainActor () -> Void] = []
        let pacer = SpawnPacer(interval: interval, now: { clock }, schedule: { _, body in wakes.append(body) })
        let registry = SpawnRegistry(pacer: pacer)
        let keys = sessions.map { _ in UUID() }
        pacer.arm(order: keys, burst: [])
        for (session, key) in zip(sessions, keys) {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            registry.enqueue(view, key: key, provider: LaunchSeedProvider(shouldPace: true) { _ in
                LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
            })
            XCTAssertFalse(view.requestSpawnPermit())
            session.surface = view
        }
        let members = [DashboardMember(session: sessions[2].id, surface: .primary),
                       DashboardMember(session: sessions[1].id, surface: .primary)]

        DashboardView.prioritizeSpawns(of: members, in: store)

        XCTAssertNotNil(registry.view(for: keys[2]), "prioritize reorders; it releases nothing")
        wakes.removeFirst()()
        XCTAssertNil(registry.view(for: keys[2]), "the first cell is granted first")
        XCTAssertNotNil(registry.view(for: keys[1]))
        wakes.removeFirst()()
        XCTAssertNotNil(registry.view(for: keys[1]), "a wake before the interval elapses grants nothing")
        clock += interval
        wakes.removeFirst()()
        XCTAssertNil(registry.view(for: keys[1]), "the second cell follows one interval later")
        XCTAssertNotNil(registry.view(for: keys[0]), "the pane outside the dashboard waits its turn")
    }

    func testAMemberWithNoQueuedPaneIsSkipped() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        session.surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())

        DashboardView.prioritizeSpawns(of: [DashboardMember(session: session.id, surface: .primary),
                                            DashboardMember(session: UUID(), surface: .split)], in: store)

        XCTAssertTrue((session.surface as? GhosttySurfaceView)?.requestSpawnPermit() ?? false)
    }

    /// Mounts the real view: its `onChange(initial:)` is the only production call, so this is what goes red
    /// when that modifier is dropped. The window is 2 points wide so every cell lays out at zero size and
    /// the one grant fired here parks on the size guard instead of spawning a shell in the test host.
    func testMountingTheViewPrioritizesItsMembersInCellOrder() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let sessions = try (0..<3).map { _ in
            try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        }
        var wakes: [@MainActor () -> Void] = []
        let pacer = SpawnPacer(interval: .milliseconds(120), now: { ContinuousClock().now },
                               schedule: { _, body in wakes.append(body) })
        let registry = SpawnRegistry(pacer: pacer)
        let keys = sessions.map { _ in UUID() }
        pacer.arm(order: keys, burst: [])
        var queued: [UUID: GhosttySurfaceView] = [:]
        for (session, key) in zip(sessions, keys) {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            registry.enqueue(view, key: key, provider: LaunchSeedProvider(shouldPace: true) { _ in
                LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
            })
            XCTAssertFalse(view.requestSpawnPermit())
            queued[session.id] = view
        }
        let controller = DashboardController()
        controller.open(members: [DashboardMember(session: sessions[2].id, surface: .primary),
                                  DashboardMember(session: sessions[1].id, surface: .primary)])
        var mounted = 0
        let dashboard = DashboardView(
            controller: controller, store: store,
            makeSurface: { session in mounted += 1; return queued[session.id]! },
            makeSplitSurface: { _ in XCTFail("no split member"); return GhosttySurfaceView(workingDirectory: "/tmp") },
            highlightColor: .white, captionBackground: .black, pillColor: .gray, pillTextColor: .white,
            focusAllowed: false, showsTopHairline: false, onClick: { _ in }, onSelect: { _ in }, onClose: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: dashboard)
        window.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while mounted < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(mounted, 2, "both cells must mount their queued pane")
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

        try XCTUnwrap(wakes.first)()

        XCTAssertNil(registry.view(for: keys[2]), "the first cell must be granted ahead of the model order")
        XCTAssertNotNil(registry.view(for: keys[0]), "the model head waits behind the dashboard's members")
        XCTAssertTrue(queued.values.allSatisfy { !$0.isRealized }, "nothing may spawn in the test host")
    }
}
