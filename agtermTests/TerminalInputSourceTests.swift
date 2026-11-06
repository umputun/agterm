import AppKit
import WebKit
import XCTest
@testable import agterm

@MainActor
final class TerminalInputSourceTests: XCTestCase {
    func testLiveSurfaceHoldsTheLockUntilTornDown() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        surface.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        XCTAssertFalse(TerminalInputSource.holdsLock(surface), "no surface before the view joins a window")
        fixture.window.contentView = surface
        fixture.window.orderFront(nil)
        XCTAssertTrue(TerminalInputSource.holdsLock(surface))
        surface.teardown()
        XCTAssertFalse(TerminalInputSource.holdsLock(surface))
    }

    func testPageAndItsSubviewsHoldTheLock() {
        let webView = HtmlOverlayWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let inner = NSView()
        webView.addSubview(inner)

        XCTAssertTrue(TerminalInputSource.holdsLock(webView))
        XCTAssertTrue(TerminalInputSource.holdsLock(inner))
    }

    func testTextFieldsAndChromeReleaseTheLock() {
        XCTAssertFalse(TerminalInputSource.holdsLock(nil))
        XCTAssertFalse(TerminalInputSource.holdsLock(NSView()))
        XCTAssertFalse(TerminalInputSource.holdsLock(NSTextView()))
    }
}
