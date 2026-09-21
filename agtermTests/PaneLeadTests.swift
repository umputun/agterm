import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class PaneLeadTests: XCTestCase {
    private var panes: [UUID] = []
    private var reattached: [(view: GhosttySurfaceView, claim: Bool)] = []

    override func setUp() async throws {
        try await super.setUp()
        PaneLead.reattach = { [unowned self] view, claim in reattached.append((view, claim)) }
    }

    override func tearDown() async throws {
        panes.forEach(ZmxLeadBook.shared.forget)
        PaneLead.reattach = nil
        PaneLead.roleChanged = nil
        try await super.tearDown()
    }

    private func pane(nonce: String = "n") -> (GhosttySurfaceView, UUID) {
        let identity = UUID()
        panes.append(identity)
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                      env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: nonce, claim: true), pane: identity)
        return (view, identity)
    }

    private func notice(_ body: String) throws -> ZmxLeadNotice {
        try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;" + body))
    }

    private func key(_ type: NSEvent.EventType, code: UInt16, repeating: Bool = false,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "a",
                                       charactersIgnoringModifiers: "a", isARepeat: repeating, keyCode: code))
    }

    func testAReportCoversThePaneAndALeaderReportUncoversIt() throws {
        let (view, _) = pane()
        var changed = 0
        PaneLead.roleChanged = { _ in changed += 1 }

        PaneLead.report(try notice("n:follower:1"), from: view)
        XCTAssertTrue(view.leadCovered)
        PaneLead.report(try notice("n:follower:1"), from: view)
        PaneLead.report(try notice("n:leader:2"), from: view)

        XCTAssertFalse(view.leadCovered)
        XCTAssertEqual(changed, 2, "a repeated report changes nothing")
        XCTAssertTrue(reattached.isEmpty)
    }

    func testAnUnownedSessionIsReattachedWithoutTheClaim() throws {
        let (view, _) = pane()

        PaneLead.report(try notice("n:unowned:3"), from: view)

        XCTAssertEqual(reattached.map(\.claim), [false],
                       "so it cannot take a lead someone claimed while it was on its way")
        XCTAssertTrue(reattached.first?.view === view)
    }

    func testAReportFromAReplacedOrForgedAttachmentIsDropped() throws {
        let (view, _) = pane(nonce: "current")

        PaneLead.report(try notice("previous:unowned:9"), from: view)

        XCTAssertFalse(view.leadCovered)
        XCTAssertTrue(reattached.isEmpty)
    }

    func testTheFirstKeyOnACoveredPaneTakesTheLeadAndIsSwallowedUntilReleased() throws {
        let (view, identity) = pane()
        PaneLead.report(try notice("n:follower:1"), from: view)

        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0), in: view))
        XCTAssertEqual(reattached.map(\.claim), [true])

        // the app's re-attach starts a fresh attachment, covered until its first report
        let fresh = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                       env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "fresh", claim: true), pane: identity, reattaching: true)
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 1), in: fresh), "typed while taking over is not replayed")
        XCTAssertEqual(reattached.count, 1, "and asks for no second attach")

        PaneLead.report(try notice("fresh:leader:2"), from: fresh)
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0, repeating: true), in: fresh))
        XCTAssertTrue(PaneLead.consumes(try key(.keyUp, code: 0), in: fresh))
        XCTAssertFalse(PaneLead.consumes(try key(.keyDown, code: 0), in: fresh), "the next press is the program's")
        XCTAssertFalse(PaneLead.consumes(try key(.keyUp, code: 0), in: fresh))
    }

    func testACommandChordOnACoveredPaneIsSwallowedWithoutTakingTheLead() throws {
        let (view, _) = pane()
        PaneLead.report(try notice("n:follower:1"), from: view)

        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 9, flags: .command), in: view))

        XCTAssertTrue(reattached.isEmpty)
    }

    func testAnUncoveredPanesKeysAreItsOwn() throws {
        let (view, _) = pane()
        PaneLead.report(try notice("n:leader:1"), from: view)

        XCTAssertFalse(PaneLead.consumes(try key(.keyDown, code: 0), in: view))
        XCTAssertFalse(PaneLead.consumes(try key(.keyUp, code: 0), in: view))
    }
}
