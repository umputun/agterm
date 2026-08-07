import XCTest

/// End-to-end coverage for nested sessions over the control channel: `session.new --parent` creates a
/// child, `session.move --parent`/`--unparent` reparents/promotes, `session.new --after` inherits the
/// anchor's parent, and the mutually-exclusive placement guards. Asserts the new `tree` `parentID`
/// read-back plus the persisted session order (which must stay in depth-first preorder).
@MainActor
final class NestedSessionsUITests: ControlAPITestCase {
    private let home = NSHomeDirectory()

    // session.new --parent nests the new session as the parent's last child, right after it and ahead of an
    // unrelated top-level sibling; the tree node reports parentID.
    func testSessionNewParentCreatesChild() throws {
        let parentID = UUID(uuidString: "F1110000-0000-0000-0000-000000000001")!
        let siblingID = UUID(uuidString: "F2220000-0000-0000-0000-000000000002")!
        try relaunch(withSnapshot: """
        {"version":1,"selectedSessionID":"\(parentID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(parentID.uuidString)","customName":null,"cwd":"\(home)"},\
        {"id":"\(siblingID.uuidString)","customName":null,"cwd":"\(home)"}]}]}
        """)
        XCTAssertTrue(pollSessionOrder([parentID, siblingID], timeout: 10), "should start in seeded order")

        let resp = try sendCommand(#"{"cmd":"session.new","args":{"parent":"\#(parentID.uuidString)"}}"#)
        XCTAssertEqual(resp["ok"] as? Bool, true, "session.new --parent should succeed: \(resp)")
        let childID = try XCTUnwrap(((resp["result"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)),
                                    "session.new should return the new id: \(resp)")
        XCTAssertTrue(pollParentID(of: childID, equals: parentID.uuidString, timeout: 10),
                      "the tree node should report the child's parentID")
        XCTAssertTrue(pollSessionOrder([parentID, childID, siblingID], timeout: 10),
                      "the child should land as the parent's last child, ahead of the sibling")
    }

    // session.move --parent reparents a top-level session under another, moving it to the parent's last-child
    // slot (right after the parent) in preorder.
    func testSessionMoveParentReparents() throws {
        let parentID = UUID(uuidString: "F3330000-0000-0000-0000-000000000001")!
        let siblingID = UUID(uuidString: "F4440000-0000-0000-0000-000000000002")!
        let movedID = UUID(uuidString: "F5550000-0000-0000-0000-000000000003")!
        try relaunch(withSnapshot: """
        {"version":1,"selectedSessionID":"\(parentID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(parentID.uuidString)","customName":null,"cwd":"\(home)"},\
        {"id":"\(siblingID.uuidString)","customName":null,"cwd":"\(home)"},\
        {"id":"\(movedID.uuidString)","customName":null,"cwd":"\(home)"}]}]}
        """)
        XCTAssertTrue(pollSessionOrder([parentID, siblingID, movedID], timeout: 10), "should start in seeded order")

        let resp = try sendCommand(#"{"cmd":"session.move","target":"\#(movedID.uuidString)","args":{"parent":"\#(parentID.uuidString)"}}"#)
        XCTAssertEqual(resp["ok"] as? Bool, true, "session.move --parent should succeed: \(resp)")
        XCTAssertTrue(pollParentID(of: movedID, equals: parentID.uuidString, timeout: 10),
                      "the moved session should now report the new parentID")
        XCTAssertTrue(pollSessionOrder([parentID, movedID, siblingID], timeout: 10),
                      "the reparented session should land right after its new parent, preorder-repaired")
    }

    // session.move --unparent promotes a nested session back to top-level: parentID drops off the tree node.
    func testSessionMoveUnparentPromotesToTopLevel() throws {
        let parentID = UUID(uuidString: "F6660000-0000-0000-0000-000000000001")!
        let childID = UUID(uuidString: "F7770000-0000-0000-0000-000000000002")!
        try relaunch(withSnapshot: """
        {"version":1,"selectedSessionID":"\(parentID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(parentID.uuidString)","customName":null,"cwd":"\(home)"},\
        {"id":"\(childID.uuidString)","customName":null,"cwd":"\(home)","parentID":"\(parentID.uuidString)"}]}]}
        """)
        XCTAssertTrue(pollParentID(of: childID, equals: parentID.uuidString, timeout: 10),
                      "the seeded child should start nested under the parent")

        let resp = try sendCommand(#"{"cmd":"session.move","target":"\#(childID.uuidString)","args":{"unparent":true}}"#)
        XCTAssertEqual(resp["ok"] as? Bool, true, "session.move --unparent should succeed: \(resp)")
        XCTAssertTrue(pollParentID(of: childID, equals: nil, timeout: 10),
                      "the promoted session's tree node should omit parentID")
        XCTAssertTrue(pollSessionOrder([parentID, childID], timeout: 10), "both sessions remain, now top-level")
    }

    // session.new --after a NESTED anchor inherits the anchor's parent, landing as a sibling right after it.
    func testSessionNewAfterChildInheritsParent() throws {
        let parentID = UUID(uuidString: "F8880000-0000-0000-0000-000000000001")!
        let childID = UUID(uuidString: "F9990000-0000-0000-0000-000000000002")!
        try relaunch(withSnapshot: """
        {"version":1,"selectedSessionID":"\(parentID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(parentID.uuidString)","customName":null,"cwd":"\(home)"},\
        {"id":"\(childID.uuidString)","customName":null,"cwd":"\(home)","parentID":"\(parentID.uuidString)"}]}]}
        """)
        XCTAssertTrue(pollParentID(of: childID, equals: parentID.uuidString, timeout: 10),
                      "the seeded child should start nested under the parent")

        let resp = try sendCommand(#"{"cmd":"session.new","args":{"after":"\#(childID.uuidString)"}}"#)
        XCTAssertEqual(resp["ok"] as? Bool, true, "session.new --after should succeed: \(resp)")
        let newID = try XCTUnwrap(((resp["result"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)),
                                  "session.new should return the new id: \(resp)")
        XCTAssertTrue(pollParentID(of: newID, equals: parentID.uuidString, timeout: 10),
                      "the new session should INHERIT the anchor child's parent")
        XCTAssertTrue(pollSessionOrder([parentID, childID, newID], timeout: 10),
                      "the new session should land right after the anchor child")
    }

    // session.move --after an anchor that already shares the target's parent AND has its own subtree must
    // keep the tree contiguous: the moved session lands after the anchor's WHOLE subtree, not between the
    // anchor and its children (regression — the flat splice used to orphan the anchor's descendants).
    func testSessionMoveAfterSubtreeBearingSiblingStaysContiguous() throws {
        let p = UUID(uuidString: "FA100000-0000-0000-0000-000000000001")!
        let c1 = UUID(uuidString: "FA200000-0000-0000-0000-000000000002")!
        let c1x = UUID(uuidString: "FA300000-0000-0000-0000-000000000003")!
        let c2 = UUID(uuidString: "FA400000-0000-0000-0000-000000000004")!
        try relaunch(withSnapshot: """
        {"version":1,"selectedSessionID":"\(p.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(p.uuidString)","customName":null,"cwd":"\(home)"},\
        {"id":"\(c1.uuidString)","customName":null,"cwd":"\(home)","parentID":"\(p.uuidString)"},\
        {"id":"\(c1x.uuidString)","customName":null,"cwd":"\(home)","parentID":"\(c1.uuidString)"},\
        {"id":"\(c2.uuidString)","customName":null,"cwd":"\(home)","parentID":"\(p.uuidString)"}]}]}
        """)
        XCTAssertTrue(pollSessionOrder([p, c1, c1x, c2], timeout: 10), "should start in seeded preorder")

        let resp = try sendCommand(#"{"cmd":"session.move","target":"\#(c2.uuidString)","args":{"after":"\#(c1.uuidString)"}}"#)
        XCTAssertEqual(resp["ok"] as? Bool, true, "session.move --after should succeed: \(resp)")
        XCTAssertTrue(pollSessionOrder([p, c1, c1x, c2], timeout: 10),
                      "c2 must land after c1's whole subtree, keeping [p, c1, c1x, c2] contiguous")
        XCTAssertTrue(pollParentID(of: c1x, equals: c1.uuidString, timeout: 10),
                      "c1's child must stay under c1 (subtree not orphaned by the move)")
        XCTAssertTrue(pollParentID(of: c2, equals: p.uuidString, timeout: 10),
                      "c2 keeps its parent p (sibling of c1)")
    }

    // --parent self-identifies the destination, so it is mutually exclusive with a workspace and with a
    // placement anchor; and on session.move it cannot combine with --unparent.
    func testNestingPlacementGuards() throws {
        let withWorkspace = try sendCommand(#"{"cmd":"session.new","args":{"parent":"active","workspace":"active"}}"#)
        XCTAssertEqual(withWorkspace["ok"] as? Bool, false, "--parent + a workspace should fail")
        XCTAssertEqual(withWorkspace["error"] as? String,
                       "session.new takes --parent, --after/--before, or a workspace, not more than one",
                       "should return the exclusivity guard: \(withWorkspace)")

        let withAfter = try sendCommand(#"{"cmd":"session.new","args":{"parent":"active","after":"active"}}"#)
        XCTAssertEqual(withAfter["ok"] as? Bool, false, "--parent + --after should fail")
        XCTAssertEqual(withAfter["error"] as? String,
                       "session.new takes --parent, --after/--before, or a workspace, not more than one",
                       "should return the exclusivity guard: \(withAfter)")

        let parentAndUnparent = try sendCommand(#"{"cmd":"session.move","target":"active","args":{"parent":"active","unparent":true}}"#)
        XCTAssertEqual(parentAndUnparent["ok"] as? Bool, false, "--parent + --unparent should fail")
        XCTAssertEqual(parentAndUnparent["error"] as? String, "use either --parent or --unparent, not both",
                       "should return the either/or guard: \(parentAndUnparent)")
    }

    // session.collapse/.expand fold a parent's subtree; the tree node's `collapsed` read-back reflects the
    // persisted Session.isExpanded (true only when collapsed), independent of a visible sidebar.
    func testSessionCollapseAndExpandReflectInTree() throws {
        let parentID = UUID(uuidString: "FB100000-0000-0000-0000-000000000001")!
        let childID = UUID(uuidString: "FB200000-0000-0000-0000-000000000002")!
        try relaunch(withSnapshot: """
        {"version":1,"selectedSessionID":"\(parentID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(parentID.uuidString)","customName":null,"cwd":"\(home)"},\
        {"id":"\(childID.uuidString)","customName":null,"cwd":"\(home)","parentID":"\(parentID.uuidString)"}]}]}
        """)
        XCTAssertTrue(pollParentID(of: childID, equals: parentID.uuidString, timeout: 10), "child starts nested")
        XCTAssertTrue(pollCollapsed(of: parentID, equals: nil, timeout: 10), "parent starts expanded (key omitted)")

        let collapse = try sendCommand(#"{"cmd":"session.collapse","target":"\#(parentID.uuidString)"}"#)
        XCTAssertEqual(collapse["ok"] as? Bool, true, "session.collapse should succeed: \(collapse)")
        XCTAssertTrue(pollCollapsed(of: parentID, equals: true, timeout: 10), "the collapsed parent reports collapsed:true")

        let expand = try sendCommand(#"{"cmd":"session.expand","target":"\#(parentID.uuidString)"}"#)
        XCTAssertEqual(expand["ok"] as? Bool, true, "session.expand should succeed: \(expand)")
        XCTAssertTrue(pollCollapsed(of: parentID, equals: nil, timeout: 10), "the re-expanded parent omits collapsed")
    }

    // GUI: the nested outline renders a child as its own row, and collapsing the parent FOLDS the descendant
    // row away (the row count drops), then expanding brings it back — proving Task 7's nested render + fold in
    // the real sidebar, not just the tree read-back.
    func testCollapseFoldsDescendantRowInSidebar() throws {
        let parentID = UUID(uuidString: "FC100000-0000-0000-0000-000000000001")!
        let childID = UUID(uuidString: "FC200000-0000-0000-0000-000000000002")!
        let siblingID = UUID(uuidString: "FC300000-0000-0000-0000-000000000003")!
        try relaunch(withSnapshot: """
        {"version":1,"selectedSessionID":"\(siblingID.uuidString)","workspaces":[\
        {"id":"\(UUID().uuidString)","name":"workspace 1","sessions":[\
        {"id":"\(parentID.uuidString)","customName":"parent","cwd":"\(home)"},\
        {"id":"\(childID.uuidString)","customName":"child","cwd":"\(home)","parentID":"\(parentID.uuidString)"},\
        {"id":"\(siblingID.uuidString)","customName":"sibling","cwd":"\(home)"}]}]}
        """)
        XCTAssertTrue(pollSessionRowCount(3, timeout: 15), "the nested child renders as its own row (parent, child, sibling)")

        let collapse = try sendCommand(#"{"cmd":"session.collapse","target":"\#(parentID.uuidString)"}"#)
        XCTAssertEqual(collapse["ok"] as? Bool, true, "session.collapse should succeed: \(collapse)")
        XCTAssertTrue(pollSessionRowCount(2, timeout: 15), "collapsing the parent folds the child row away")

        let expand = try sendCommand(#"{"cmd":"session.expand","target":"\#(parentID.uuidString)"}"#)
        XCTAssertEqual(expand["ok"] as? Bool, true, "session.expand should succeed: \(expand)")
        XCTAssertTrue(pollSessionRowCount(3, timeout: 15), "expanding the parent brings the child row back")
    }

    /// Polls the live `tree` until the (present) session's `parentID` read-back equals `expected` (nil = the
    /// key is omitted, i.e. top-level). An absent session never matches, so it keeps polling until timeout.
    private func pollParentID(of id: UUID, equals expected: String?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let want = expected?.lowercased()
        while true {
            if let node = (try? sessionNodeIfPresent(id: id.uuidString)) ?? nil,
               (node["parentID"] as? String)?.lowercased() == want {
                return true
            }
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    /// Polls the live `tree` until the (present) session's `collapsed` read-back equals `expected` (nil =
    /// the key is omitted, i.e. expanded — the byte-compatible default). An absent session never matches.
    private func pollCollapsed(of id: UUID, equals expected: Bool?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let node = (try? sessionNodeIfPresent(id: id.uuidString)) ?? nil,
               (node["collapsed"] as? Bool) == expected {
                return true
            }
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
