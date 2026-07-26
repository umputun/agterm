import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the per-window scoping of the inline-rename notifications. The sidebar owns the
/// edit field, so `AppActions.renameActive{Session,Workspace}` reach it by notification; the object those
/// posts carry is what decides WHICH window's sidebar starts an edit. `WorkspaceSidebar.Coordinator`
/// registers with `object: store`, so a post carrying a different store (or nil) must not reach it.
///
/// This asserts the post's object rather than driving a real sidebar: the Coordinator needs a live
/// `NSOutlineView` and a row to edit, while the defect being pinned is entirely in the addressing.
@MainActor
final class InlineRenameScopeTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var tokens: [NSObjectProtocol] = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-rename-scope-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens.removeAll()
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    // A rename started from the menu / palette / keymap must open an editor in the FRONTMOST window only.
    // Posting with a nil object reached every open window's coordinator — their `selectedSessionID` guard
    // is not a scope, since every window has a selection — so each one opened an editor the user never
    // asked for and leaked an unbalanced `suppressAutoFollow`, wedging that window's idle auto-follow off.
    func testRenameSessionPostsScopedToTheFrontmostStore() throws {
        let (frontStore, otherStore) = try twoWindows()
        let front = observe(.agtermBeginRenameSession, object: frontStore)
        let other = observe(.agtermBeginRenameSession, object: otherStore)

        actions.renameActiveSession()

        XCTAssertEqual(front.count, 1, "the frontmost window's sidebar should be asked to start the edit")
        XCTAssertEqual(other.count, 0, "a background window's sidebar must not start an edit it never asked for")
    }

    func testRenameWorkspacePostsScopedToTheFrontmostStore() throws {
        let (frontStore, otherStore) = try twoWindows()
        let front = observe(.agtermBeginRenameWorkspace, object: frontStore)
        let other = observe(.agtermBeginRenameWorkspace, object: otherStore)

        actions.renameActiveWorkspace()

        XCTAssertEqual(front.count, 1, "the frontmost window's sidebar should be asked to start the edit")
        XCTAssertEqual(other.count, 0, "a background window's sidebar must not start an edit it never asked for")
    }

    /// Opens a second window and leaves the FIRST one frontmost, returning (frontmost store, other store).
    private func twoWindows() throws -> (AppStore, AppStore) {
        let frontID = try XCTUnwrap(library.activeWindowID)
        let frontStore = try XCTUnwrap(library.activeStore)
        let otherID = library.newWindow(name: "window B").id
        let otherStore = try XCTUnwrap(library.loadStore(for: otherID))
        library.frontmostWindowID = frontID
        XCTAssertFalse(frontStore === otherStore, "the two windows must own distinct stores")
        return (frontStore, otherStore)
    }

    /// Counts deliveries of `name` filtered to `object`, mirroring how the sidebar coordinator registers.
    private func observe(_ name: Notification.Name, object: AnyObject) -> Counter {
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: name, object: object, queue: nil
        ) { _ in counter.count += 1 }
        tokens.append(token)
        return counter
    }

    private final class Counter {
        var count = 0
    }
}
