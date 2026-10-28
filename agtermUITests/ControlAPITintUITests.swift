import XCTest

/// End-to-end tests for `session.tint` and `workspace.tint` over the control socket: create tinted, recolor,
/// move the placement, clear, and read each step back from `tree` and the sidebar icon's accessibility value.
@MainActor
final class ControlAPITintUITests: ControlAPITestCase {
    func testTintCreateSetAndClearReadBack() throws {
        let workspace = try sendCommand(#"{"cmd":"workspace.new","args":{"name":"prod","tint":"red","tintOn":["name"]}}"#)
        XCTAssertEqual(workspace["ok"] as? Bool, true, "\(workspace)")
        let workspaceID = try XCTUnwrap((workspace["result"] as? [String: Any])?["id"] as? String)
        let created = try sendCommand(
            #"{"cmd":"session.new","args":{"workspace":"\#(workspaceID)","name":"db","tint":"orange","noSelect":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let sessionID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)

        let node = try workspaceNode(id: workspaceID)
        XCTAssertEqual(node["tint"] as? String, "red")
        XCTAssertEqual(node["tintOn"] as? [String], ["name"])
        XCTAssertEqual(try sessionNode(id: sessionID)["tint"] as? String, "orange")
        XCTAssertEqual(try sessionNode(id: sessionID)["tintOn"] as? [String], ["icon"])
        XCTAssertTrue(poll(until: self.app.images.matching(identifier: "session-icon")
            .matching(NSPredicate(format: "value == %@", "orange tint")).count == 1, timeout: 5),
                      "the tinted row's icon should name its tint")

        let moved = try sendCommand(#"{"cmd":"session.tint","target":"\#(sessionID)","args":{"mode":"set","tint":"green","tintOn":["icon","name"]}}"#)
        XCTAssertEqual(moved["ok"] as? Bool, true, "\(moved)")
        XCTAssertEqual(try sessionNode(id: sessionID)["tint"] as? String, "green")
        XCTAssertEqual(try sessionNode(id: sessionID)["tintOn"] as? [String], ["icon", "name"])

        let refused = try sendCommand(#"{"cmd":"session.tint","target":"\#(sessionID)","args":{"mode":"clear","tint":"red"}}"#)
        XCTAssertEqual(refused["ok"] as? Bool, false, "a clear carrying a color must be refused: \(refused)")
        XCTAssertEqual(try sessionNode(id: sessionID)["tint"] as? String, "green", "a refused call changes nothing")

        let cleared = try sendCommand(#"{"cmd":"session.tint","target":"\#(sessionID)","args":{"mode":"clear"}}"#)
        XCTAssertEqual(cleared["ok"] as? Bool, true, "\(cleared)")
        XCTAssertNil(try sessionNode(id: sessionID)["tint"])
        XCTAssertNil(try sessionNode(id: sessionID)["tintOn"])

        let workspaceCleared = try sendCommand(#"{"cmd":"workspace.tint","target":"\#(workspaceID)","args":{"mode":"clear"}}"#)
        XCTAssertEqual(workspaceCleared["ok"] as? Bool, true, "\(workspaceCleared)")
        XCTAssertNil(try workspaceNode(id: workspaceID)["tint"])
    }

    private func workspaceNode(id: String) throws -> [String: Any] {
        let tree = try sendCommand(#"{"cmd":"tree"}"#)
        let result = try XCTUnwrap(tree["result"] as? [String: Any])
        let workspaces = try XCTUnwrap((result["tree"] as? [String: Any])?["workspaces"] as? [[String: Any]])
        return try XCTUnwrap(workspaces.first { $0["id"] as? String == id }, "workspace \(id) should be in the tree")
    }
}
