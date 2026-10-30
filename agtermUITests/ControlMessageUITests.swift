import XCTest

@MainActor
final class ControlMessageUITests: ControlAPITestCase {
    func testTwoPanesExchangeAMessageThroughTheSocketAndAckClearsThePendingCount() throws {
        let (sessionID, left, right) = try splitPanes()

        let send = try sendControl(["cmd": "msg.send", "args": ["body": "hello right", "recipients": ["\(sessionID):right"],
                                                                "identity": "\(sessionID):\(left)"]])
        XCTAssertEqual(send["ok"] as? Bool, true, "send should succeed: \(send)")
        XCTAssertEqual(pendingMessages(sessionID, paneID: right), 1)

        let read = try sendControl(["cmd": "msg.read", "args": ["identity": "\(sessionID):\(right)"]])
        let messages = try XCTUnwrap((read["result"] as? [String: Any])?["messages"] as? [[String: Any]], "\(read)")
        XCTAssertEqual(messages.map { $0["body"] as? String }, ["hello right"])
        XCTAssertEqual(messages.first?["from"] as? String, "\(sessionID):\(left)")
        let id = try XCTUnwrap(messages.first?["id"] as? String)

        let ack = try sendControl(["cmd": "msg.ack", "args": ["identity": "\(sessionID):\(right)", "ids": [id]]])
        XCTAssertEqual((ack["result"] as? [String: Any])?["acked"] as? [String], [id])
        XCTAssertNil(pendingMessages(sessionID, paneID: right))
    }

    func testASwapKeepsTheMailboxWithItsPaneID() throws {
        let (sessionID, _, right) = try splitPanes()
        _ = try sendControl(["cmd": "msg.send", "args": ["body": "follow me", "recipients": ["\(sessionID):\(right)"]]])

        XCTAssertEqual(try sendCommand(#"{"cmd":"session.swap","target":"\#(sessionID)"}"#)["ok"] as? Bool, true)

        XCTAssertTrue(poll(until: self.paneKind(sessionID, paneID: right) == "left", timeout: 5), "the swapped pane should sit on the left")
        XCTAssertEqual(pendingMessages(sessionID, paneID: right), 1)
    }

    func testReadWithAckEmptiesTheMailboxAndTheNextReadIsEmpty() throws {
        let (sessionID, left, _) = try splitPanes()
        _ = try sendControl(["cmd": "msg.send", "args": ["body": "once", "recipients": ["\(sessionID):\(left)"]]])

        let taken = try sendControl(["cmd": "msg.read", "args": ["identity": "\(sessionID):\(left)", "ack": true]])
        let again = try sendControl(["cmd": "msg.read", "args": ["identity": "\(sessionID):\(left)", "ack": true]])

        XCTAssertEqual(((taken["result"] as? [String: Any])?["acked"] as? [String])?.count, 1, "\(taken)")
        XCTAssertEqual((again["result"] as? [String: Any])?["acked"] as? [String], [])
        XCTAssertEqual(((again["result"] as? [String: Any])?["messages"] as? [Any])?.count, 0)
        XCTAssertNil(pendingMessages(sessionID, paneID: left))
    }

    // MARK: - helpers

    /// splitPanes opens a split and waits until both panes are live: each carries a paneID and takes mail.
    private func splitPanes() throws -> (session: String, left: String, right: String) {
        let sessionID = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(sessionID)","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        var ids: (String, String)?
        XCTAssertTrue(poll(until: {
            guard let left = self.paneID(sessionID, kind: "left"), let right = self.paneID(sessionID, kind: "right") else { return false }
            ids = (left, right)
            return true
        }(), timeout: 15), "both panes should report a paneID")
        let (left, right) = try XCTUnwrap(ids)
        for pane in [left, right] {
            XCTAssertTrue(poll(until: self.probeDelivers(sessionID, pane), timeout: 15), "pane \(pane) should take mail")
        }
        return (sessionID, left, right)
    }

    /// probeDelivers sends one throwaway message and acks it, so a pane counts as live only once it takes mail.
    private func probeDelivers(_ sessionID: String, _ pane: String) -> Bool {
        let address = "\(sessionID):\(pane)"
        guard let sent = try? sendControl(["cmd": "msg.send", "args": ["body": "probe", "recipients": [address]]]),
              (sent["result"] as? [String: Any])?["delivered"] as? [String] == [address] else { return false }
        _ = try? sendControl(["cmd": "msg.read", "args": ["identity": address, "ack": true]])
        return true
    }

    private func surfaces(_ sessionID: String) -> [[String: Any]] {
        ((try? sessionNode(id: sessionID))?["surfaces"] as? [[String: Any]]) ?? []
    }

    private func paneID(_ sessionID: String, kind: String) -> String? {
        surfaces(sessionID).first { $0["kind"] as? String == kind }?["paneID"] as? String
    }

    private func paneKind(_ sessionID: String, paneID: String) -> String? {
        surfaces(sessionID).first { $0["paneID"] as? String == paneID }?["kind"] as? String
    }

    private func pendingMessages(_ sessionID: String, paneID: String) -> Int? {
        surfaces(sessionID).first { $0["paneID"] as? String == paneID }?["pendingMessages"] as? Int
    }

    private func sendControl(_ request: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: request)
        return try sendCommand(String(decoding: data, as: UTF8.self))
    }
}
