import AppKit
import SwiftUI
import XCTest
@testable import agterm

@MainActor
final class NativeToolTipTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window?.close()
            window = nil
        }
        try await super.tearDown()
    }

    func testTheControlCarriesAnAppKitToolTipThatFollowsItsText() throws {
        let host = NSHostingView(rootView: button(tip: "Show split (⌘D)"))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let tip = try XCTUnwrap(descendants(NativeToolTip.ToolTipView.self, in: host).first)
        XCTAssertEqual(tip.toolTip, "Show split (⌘D)")
        XCTAssertGreaterThan(tip.frame.width, 0)

        host.rootView = button(tip: "Hide split (⌘D)")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(descendants(NativeToolTip.ToolTipView.self, in: host).map(\.toolTip), ["Hide split (⌘D)"])
    }

    func testTheToolTipViewNeverTakesAClick() throws {
        let host = NSHostingView(rootView: button(tip: "Scratch"))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let tip = try XCTUnwrap(descendants(NativeToolTip.ToolTipView.self, in: host).first)
        let center = NSPoint(x: tip.bounds.midX, y: tip.bounds.midY)
        XCTAssertNil(tip.hitTest(tip.convert(center, to: tip.superview)))
        XCTAssertFalse(host.hitTest(tip.convert(center, to: host.superview)) is NativeToolTip.ToolTipView)
    }

    func testAHiddenControlCarriesNoToolTipUntilShownAgain() throws {
        let host = NSHostingView(rootView: button(tip: "New Workspace", shown: false))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let tip = try XCTUnwrap(descendants(NativeToolTip.ToolTipView.self, in: host).first)
        XCTAssertNil(tip.toolTip)

        host.rootView = button(tip: "New Workspace", shown: true)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(descendants(NativeToolTip.ToolTipView.self, in: host).map(\.toolTip), ["New Workspace"])
    }

    private func button(tip: String, shown: Bool = true) -> some View {
        Button {} label: { Label("Scratch", systemImage: "square") }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .toolTip(tip, isShown: shown)
            .frame(width: 200, height: 100)
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub in (sub as? T).map { [$0] } ?? descendants(type, in: sub) }
    }
}
