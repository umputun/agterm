import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppActionsOverlayTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-actions-overlay-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        library = WindowLibrary(directory: stateDir)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        actions = AppActions(library: library)
        actions.settingsModel = settings
    }

    override func tearDown() async throws {
        actions = nil
        settings = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    private func activeSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        return (store, try XCTUnwrap(store.activeSession))
    }

    func testCommandWSkipsAHiddenSessionOverlayAndClosesTheFocusedPaneOverlay() throws {
        let (store, session) = try activeSession()
        XCTAssertTrue(store.openOverlay(session.id, command: "less"))
        XCTAssertNil(store.openPaneOverlay(session.id, pane: .left, command: "htop"))
        session.overlayHidden = true

        XCTAssertTrue(actions.closeActiveSession())

        XCTAssertNil(session.paneOverlay(.left), "the visible pane overlay is the one in front")
        XCTAssertTrue(session.overlayActive, "the hidden session overlay stays")
        XCTAssertTrue(session.overlayHidden)
    }

    func testCommandWWithOnlyHiddenOverlaysClosesTheSession() throws {
        let (store, session) = try activeSession()
        XCTAssertTrue(store.openOverlay(session.id, command: "less"))
        XCTAssertNil(store.openPaneOverlay(session.id, pane: .left, command: "htop"))
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)

        XCTAssertTrue(actions.closeActiveSession())

        XCTAssertNil(store.workspaces.flatMap(\.sessions).first { $0.id == session.id })
    }

    func testEditKeymapRefusedByAHiddenOverlayLeavesItHidden() throws {
        let (store, session) = try activeSession()
        XCTAssertTrue(store.openOverlay(session.id, command: "less"))
        XCTAssertNil(store.openPaneOverlay(session.id, pane: .left, command: "htop"))
        store.setOverlaysHidden(session.id, pane: nil, hidden: true)

        actions.editKeymap()

        XCTAssertNil(actions.keymapEditOverlaySession)
        XCTAssertEqual(session.overlayCommand, "less")
        XCTAssertEqual(session.hiddenOverlayNames, ["session", "left"])
    }

    func testCloseConfirmationNamesHiddenOverlaysOnlyWhenThereAreAny() throws {
        let (store, session) = try activeSession()
        let other = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: "/tmp"))
        XCTAssertTrue(store.openOverlay(session.id, command: "less"))

        XCTAssertEqual(actions.closeConfirmationText(for: [session]), "The session will close after a short undo window.")

        store.setOverlaysHidden(session.id, pane: nil, hidden: true)

        XCTAssertEqual(actions.closeConfirmationText(for: [session]),
                       "The session will close after a short undo window. Its hidden overlays close with it.")
        XCTAssertEqual(actions.closeConfirmationText(for: [other, session]),
                       "The sessions will close after a short undo window. Their hidden overlays close with them.")
        settings.setCloseGraceUndoEnabled(false)
        XCTAssertEqual(actions.closeConfirmationText(for: [other]),
                       "The session will close immediately and can be reopened from File > Open Recent.")
    }

    func testToggleOverlaysFlipsTheActiveSessionAndThePaletteFollowsWhatIsThere() throws {
        let (store, session) = try activeSession()
        XCTAssertFalse(actions.paletteContext.activeSessionHasOverlay)
        XCTAssertFalse(PaletteCommand.toggleOverlay.isEnabled(in: actions.paletteContext))
        actions.toggleOverlays()
        XCTAssertNil(store.workspaces.flatMap(\.sessions).first { $0.hiddenOverlayNames.isEmpty == false })

        XCTAssertTrue(store.openOverlay(session.id, command: "less"))
        XCTAssertTrue(PaletteCommand.toggleOverlay.isEnabled(in: actions.paletteContext))
        actions.perform(.toggleOverlay, in: nil)
        XCTAssertEqual(session.hiddenOverlayNames, ["session"])
        actions.toggleOverlays()
        XCTAssertEqual(session.hiddenOverlayNames, [])
    }
}
