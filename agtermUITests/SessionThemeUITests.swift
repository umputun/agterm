import Foundation
import XCTest

// session.theme UI e2e; the `ControlAPITestCase` base supplies the socket/app harness helpers.
@MainActor
final class SessionThemeUITests: ControlAPITestCase {
    /// Dracula's `background` as the bundled theme file declares it, in the `rgb:RRRR/GGGG/BBBB` form
    /// ghostty answers an OSC 11 QUERY with. Pinned rather than derived: reading the app bundle's theme file
    /// from the runner would test the test, and a changed value here is a real change in what a pane renders.
    private let draculaBackground = "rgb:2828/2a2a/3636"

    /// The whole point of the feature: the themed pane recolors and its sibling does not. Asserted through
    /// an OSC 11 query, the only in-band way to ask a live surface what it is actually rendering — the tree
    /// read-back alone would pass even if the per-surface config never reached libghostty.
    func testPaneThemeRecolorsOnlyThatPane() throws {
        let id = try activeSessionID()
        let split = try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)
        XCTAssertEqual(split["ok"] as? Bool, true, "session.split should succeed: \(split)")
        XCTAssertTrue(try pollSplit(id, timeout: 10), "the split pane should come up")

        let set = try sendCommand(
            #"{"cmd":"session.theme","target":"\#(id)","args":{"mode":"set","pane":"right","light":"Dracula"}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "session.theme should succeed: \(set)")
        let node = try sessionNode(id: id)
        XCTAssertEqual((node["splitTheme"] as? [String: Any])?["light"] as? String, "Dracula")
        XCTAssertNil(node["theme"], "the unthemed main pane must stay omitted")

        let right = try queriedBackground(of: id, pane: "right")
        let left = try queriedBackground(of: id, pane: "left")
        XCTAssertEqual(right, draculaBackground, "the themed pane should render Dracula's background")
        XCTAssertNotEqual(left, right, "the sibling pane must keep the app-wide theme")
    }

    func testClearingRestoresTheAppTheme() throws {
        let id = try activeSessionID()
        let set = try sendCommand(
            #"{"cmd":"session.theme","target":"\#(id)","args":{"mode":"set","light":"Dracula"}}"#)
        XCTAssertEqual(set["ok"] as? Bool, true, "session.theme should succeed: \(set)")
        XCTAssertEqual(try queriedBackground(of: id, pane: "left"), draculaBackground)

        let cleared = try sendCommand(#"{"cmd":"session.theme","target":"\#(id)","args":{"mode":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "session.theme --clear should succeed: \(cleared)")
        XCTAssertNil(try sessionNode(id: id)["theme"], "a cleared override must be omitted from the tree")
        XCTAssertNotEqual(try queriedBackground(of: id, pane: "left"), draculaBackground)
    }

    func testUnknownThemeIsRejected() throws {
        let id = try activeSessionID()
        let response = try sendCommand(
            #"{"cmd":"session.theme","target":"\#(id)","args":{"mode":"set","light":"No Such Theme"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "unknown theme: No Such Theme")
        XCTAssertNil(try sessionNode(id: id)["theme"], "a rejected set must not be stored")
    }

    /// Ask one pane for its rendered background: OSC 11 with a `?` payload, which ghostty answers on the pty
    /// as `<ESC>]11;rgb:…<ESC>\`. Nothing consumes the reply, so it lands in the buffer `session.text` reads.
    private func queriedBackground(of id: String, pane: String) throws -> String? {
        let typed = try sendCommand(typeRequest(text: "clear; printf '\\e]11;?\\e\\\\'\n",
                                                target: id, select: false, pane: pane))
        XCTAssertEqual(typed["ok"] as? Bool, true, "session.type should succeed: \(typed)")
        for _ in 0..<40 {
            let response = try sendCommand(#"{"cmd":"session.text","target":"\#(id)","args":{"pane":"\#(pane)"}}"#)
            if let text = (response["result"] as? [String: Any])?["text"] as? String,
               let range = text.range(of: "rgb:[0-9a-f]{4}/[0-9a-f]{4}/[0-9a-f]{4}", options: .regularExpression) {
                return String(text[range])
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }
}
