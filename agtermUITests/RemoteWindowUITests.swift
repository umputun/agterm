import XCTest

@MainActor
final class RemoteWindowUITests: ControlAPITestCase {
    private struct TreeUnavailable: Error {}

    private static let host = ProcessInfo.processInfo.environment["AGTERM_UITEST_REMOTE_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    private var windowID = ""
    private var workspaceID: String?

    override var launchEnvironmentOverrides: [String: String] {
        var environment = ["AGTERM_UITEST_ALLOW_CLOSE_CONFIRMATION": "1"]
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = agent }
        return environment
    }

    override func setUp() async throws {
        guard let host = Self.host else {
            throw XCTSkip("set TEST_RUNNER_AGTERM_UITEST_REMOTE_HOST to an agterm-server host ssh reaches without a prompt")
        }
        try await super.setUp()
        let reply = try sendControlCommand("window.remote.open", args: ["host": host])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        windowID = try XCTUnwrap((reply["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(poll(until: (try? self.remoteNode())?["state"] as? String == "connected", timeout: 30),
                      "the remote window should connect to \(host)")
        let name = "uitest-\(UUID().uuidString.prefix(8))"
        let workspace = try sendControlCommand("workspace.new", args: ["window": windowID, "name": name])
        XCTAssertEqual(workspace["ok"] as? Bool, true, "\(workspace)")
        workspaceID = try XCTUnwrap((workspace["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(poll(until: (try? self.ownedSessions()) != nil, timeout: 15), "the server's workspace \(name) should arrive")
    }

    override func tearDown() async throws {
        var leftover: String?
        if let workspaceID, let host = Self.host {
            do {
                let reply = try sendControlCommand("workspace.delete", target: workspaceID, args: ["window": windowID])
                if reply["ok"] as? Bool != true { leftover = "workspace \(workspaceID) is left on \(host): \(reply)" }
            } catch {
                leftover = "workspace \(workspaceID) is left on \(host): \(error)"
            }
        }
        try await super.tearDown()
        if let leftover { XCTFail(leftover) }
    }

    private func tree() throws -> [String: Any] {
        let reply = try sendControlCommand("tree", args: ["window": windowID])
        guard reply["ok"] as? Bool == true, let tree = (reply["result"] as? [String: Any])?["tree"] as? [String: Any] else {
            throw TreeUnavailable()
        }
        return tree
    }

    private func remoteNode() throws -> [String: Any] {
        guard let remote = try tree()["remote"] as? [String: Any] else { throw TreeUnavailable() }
        return remote
    }

    private func detachedSessions() throws -> [String] {
        try remoteNode()["detachedSessions"] as? [String] ?? []
    }

    private func ownedSessions() throws -> [[String: Any]] {
        let workspaces = try tree()["workspaces"] as? [[String: Any]] ?? []
        guard let owned = workspaces.first(where: { $0["id"] as? String == workspaceID }) else { throw TreeUnavailable() }
        return owned["sessions"] as? [[String: Any]] ?? []
    }

    private func node(id: String) -> [String: Any]? {
        (try? ownedSessions())?.first { $0["id"] as? String == id }
    }

    private func isGone(_ id: String) -> Bool {
        guard let sessions = try? ownedSessions() else { return false }
        return !sessions.contains { $0["id"] as? String == id }
    }

    private func isDetached(_ id: String) -> Bool {
        (try? detachedSessions())?.contains(id) == true
    }

    private func makeSession() throws -> (id: String, name: String) {
        let name = "uitest-\(UUID().uuidString.prefix(8))"
        let reply = try sendControlCommand("session.new", args: ["window": windowID, "workspace": try XCTUnwrap(workspaceID), "name": name])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let id = try XCTUnwrap((reply["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(poll(until: self.node(id: id) != nil, timeout: 15), "the server's row for \(name) should arrive")
        let select = try sendControlCommand("session.select", target: id)
        XCTAssertEqual(select["ok"] as? Bool, true, "\(select)")
        XCTAssertTrue(poll(until: self.node(id: id)?["active"] as? Bool == true, timeout: 10), "\(name) should be selected")
        return (id, name)
    }

    private func clickMenuItem(_ title: String) {
        let item = app.menuBars.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "menu item \(title) should exist")
        item.click()
    }

    private func answerClose(_ button: String) {
        app.typeKey("w", modifierFlags: .command)
        let answer = app.buttons[button]
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the close alert should offer \(button)")
        answer.click()
    }

    func testNewSessionFromTheMenuArrivesFromTheServer() throws {
        let anchor = try makeSession()
        let before = try ownedSessions().count

        clickMenuItem("New Session")

        XCTAssertTrue(poll(until: (try? self.ownedSessions())?.count == before + 1, timeout: 15),
                      "the server's new row should arrive in the workspace of \(anchor.name)")
    }

    func testToggleSplitFromTheMenuIsShownFromTheServer() throws {
        let session = try makeSession()

        clickMenuItem("Toggle Vertical Split")

        XCTAssertTrue(poll(until: self.node(id: session.id)?["split"] as? Bool == true, timeout: 15), "the server's split should show")
    }

    func testRenameFromTheMenuRenamesOnTheServer() throws {
        let session = try makeSession()
        let renamed = "\(session.name)-renamed"

        clickMenuItem("Rename Session")
        let field = app.textFields["edit-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the inline rename field should open")
        field.typeKey("a", modifierFlags: .command)
        field.typeText(renamed)
        field.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(poll(until: self.node(id: session.id)?["name"] as? String == renamed, timeout: 15), "the server's name should change")
    }

    func testClosingAndAnsweringDetachHidesTheRowAndKeepsItOnTheServer() throws {
        let session = try makeSession()

        answerClose("Detach")

        XCTAssertTrue(poll(until: self.isDetached(session.id), timeout: 10), "the row should be listed as detached")
        XCTAssertTrue(isGone(session.id), "a detached row should not be shown")
    }

    func testReattachingFromDetachedSessionsBringsTheRowBack() throws {
        let session = try makeSession()
        let detach = try sendControlCommand("session.detach", target: session.id)
        XCTAssertEqual(detach["ok"] as? Bool, true, "\(detach)")
        XCTAssertTrue(poll(until: self.isGone(session.id), timeout: 10))

        clickMenuItem("Detached Sessions…")
        XCTAssertTrue(app.staticTexts[session.name].waitForExistence(timeout: 10), "the picker should list \(session.name)")
        app.typeText(session.name)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(poll(until: self.node(id: session.id) != nil, timeout: 15), "the row should come back")
        XCTAssertFalse(try detachedSessions().contains(session.id))
    }

    func testClosingAndAnsweringTerminateEndsTheSessionOnTheServer() throws {
        let session = try makeSession()

        answerClose("Terminate")

        XCTAssertTrue(poll(until: self.isGone(session.id), timeout: 15), "the server's removal should take the row")
        XCTAssertFalse(try detachedSessions().contains(session.id))
    }
}
