import AppKit
import SwiftUI
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class TerminalViewTests: XCTestCase {
    func testStaleActiveUpdateNeverTakesFocusForATornDownSurface() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let closing = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        fixture.session.surface = closing
        let neighbour = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        defer { neighbour.teardown() }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        neighbour.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        container.addSubview(neighbour)
        let host = NSHostingView(rootView: DeckEntry(session: fixture.session, surface: closing, isActive: false))
        host.frame = CGRect(x: 300, y: 0, width: 300, height: 300)
        container.addSubview(host)
        fixture.window.contentView = container
        fixture.window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(closing.isRealized)
        neighbour.createSurface()
        XCTAssertTrue(fixture.window.makeFirstResponder(neighbour))
        XCTAssertTrue(fixture.window.firstResponder === neighbour)
        closing.teardown()
        host.rootView = DeckEntry(session: fixture.session, surface: closing, isActive: true)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(fixture.window.firstResponder === neighbour)
    }
}

private struct DeckEntry: View {
    let session: Session
    let surface: GhosttySurfaceView
    let isActive: Bool

    var body: some View {
        TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: { _ in surface }, isActive: isActive)
            .frame(width: 300, height: 300)
    }
}
