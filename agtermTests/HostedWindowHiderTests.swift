import AppKit
import XCTest

@MainActor
final class HostedWindowHiderTests: XCTestCase {
    func testAWindowCreatedInTheHostStartsTransparent() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertEqual(window.alphaValue, 0)
    }

    func testAPanelCreatedInTheHostStartsTransparentAndStillOrdersFront() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }

        panel.orderFrontRegardless()

        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(panel.isVisible)
    }
}
