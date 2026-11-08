import SwiftUI
import XCTest
@testable import agterm
import agtermCore

private struct ShownPage: View {
    let store: AppStore
    let session: Session

    var body: some View {
        if let page = session.htmlOverlay {
            HtmlOverlayView(store: store, session: session, overlay: page, backgroundColor: nil, isActive: false,
                            visible: true, toolTipsShown: true, hideShown: false, foreground: .white, background: .black)
        }
    }
}

@MainActor
final class HtmlOverlayViewTests: HtmlPageTestCase {
    func testARestoredPageWhoseFileIsMissingOffersAReloadThatLoadsItOnceTheFileAppears() async throws {
        let file = pages.appendingPathComponent("later.html")
        for (navigation, chromeless) in [(false, false), (true, false), (false, true)] {
            let shape = "navigation \(navigation), chromeless \(chromeless)"
            let overlay = HtmlOverlay(source: .file(path: file.path, grantRoot: nil), navigation: navigation, chromeless: chromeless)
            let saved = try store.addPageSession(after: session.id, overlay: overlay).get()
            let restored = AppStore(persistence: PersistenceStore(directory: directory.appendingPathComponent("restored-\(UUID())")))
            restored.restore(from: store.snapshot())
            store.closeSession(saved.id)
            let row = try XCTUnwrap(restored.session(withID: saved.id))
            let view = NSHostingView(rootView: ShownPage(store: restored, session: row))
            let window = try host(view)
            defer {
                window.orderOut(nil)
                restored.closeSession(row.id)
                try? FileManager.default.removeItem(at: file)
            }

            try await waitFor("the missing file failed") { row.htmlOverlay?.loadState == .failed }
            window.orderFront(nil)
            let reloads = toolTips("Reload", in: view)
            XCTAssertEqual(reloads.count, navigation ? 2 : 1, shape)
            let reload = try XCTUnwrap(reloads.min { $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY }, shape)
            try "<!doctype html><html><head><title>later</title></head><body>later</body></html>"
                .write(to: file, atomically: true, encoding: .utf8)
            try click(reload, in: window)

            try await waitFor("the reload loaded the file") { row.htmlOverlay?.loadState == .loaded }
            XCTAssertEqual(row.htmlOverlay?.current?.title, "later")
        }
    }

    private func toolTips(_ text: String, in root: NSView) -> [NSView] {
        (root.toolTip == text ? [root] : []) + root.subviews.flatMap { toolTips(text, in: $0) }
    }

    private func click(_ target: NSView, in window: NSWindow) throws {
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                              clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
    }
}
