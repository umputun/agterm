import AppKit
import XCTest
@testable import agterm

@MainActor
final class HostedTestPlaceholderTests: XCTestCase {
    func testPlaceholderMakesItsWindowTransparentAndClickThrough() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.alphaValue = 1

        window.contentView = HostedTestPlaceholderView()

        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    func testHostLaunchWindowIsTransparent() throws {
        let launchWindows = NSApp.windows.filter {
            $0.identifier?.rawValue.hasPrefix("terminal-AppWindow-") == true
                || (NSStringFromClass(type(of: $0)).contains("SwiftUI") && $0.title == "Agterm")
        }
        try XCTSkipIf(launchWindows.isEmpty, "FB11763863: this launch created no WindowGroup window")

        for window in launchWindows {
            XCTAssertNotNil(window.contentView?.firstDescendant(HostedTestPlaceholderView.self))
            XCTAssertEqual(window.alphaValue, 0)
            XCTAssertTrue(window.ignoresMouseEvents)
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(type) { return match }
        }
        return nil
    }
}
