import Foundation
import XCTest

// e2e for the "New sessions open in" setting. Split out of ControlAPIUITests so that file stays under
// the swiftlint file_length limit; this is an extension over the SAME test class, reusing its socket
// harness (sendCommand / activeSessionID / typeRequest / app), so no scaffolding is duplicated.
extension ControlAPIUITests {
    // with "Current session's directory" chosen, File ▸ New Session opens the new session in the ACTIVE
    // session's cwd, not home.
    func testNewSessionInheritsCurrentSessionDirectory() throws {
        let (seededID, marker, markerName) = try armCurrentSessionMode()
        defer { try? FileManager.default.removeItem(at: marker) }

        app.menuBars.menuBarItems["File"].click()
        let newSession = app.menuItems["New Session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5), "File menu should offer New Session")
        newSession.click()

        assertNewSessionInherited(seededID: seededID, markerName: markerName)
    }

    // the workspace-row right-click "New Session" is a SEPARATE entry point (WorkspaceSidebar.menuNewSession,
    // not AppActions.newSession) — it must honor the setting too. Regression guard: without the shared
    // resolvedNewSessionCwd() it hardcoded home and ignored the picker.
    func testWorkspaceRowNewSessionInheritsCurrentSessionDirectory() throws {
        let (seededID, marker, markerName) = try armCurrentSessionMode()
        defer { try? FileManager.default.removeItem(at: marker) }

        let workspaceRow = app.descendants(matching: .any).matching(identifier: "workspace-row").firstMatch
        XCTAssertTrue(workspaceRow.waitForExistence(timeout: 5), "a workspace row should exist")
        workspaceRow.rightClick()
        // scope to the open context-menu popup: "New Session" also lives in the menu bar, so an app-wide
        // menuItems query is ambiguous.
        let newSession = app.menus.menuItems["New Session"].firstMatch
        XCTAssertTrue(newSession.waitForExistence(timeout: 5), "the workspace context menu should offer New Session")
        newSession.click()

        assertNewSessionInherited(seededID: seededID, markerName: markerName)
    }

    /// Selects "Current session's directory", cds the seeded session into a fresh marker dir, and waits
    /// until the tree reflects it. Returns the seeded id, the marker dir (caller removes it), and its name.
    private func armCurrentSessionMode() throws -> (seededID: String, marker: URL, markerName: String) {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-newsess-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        let markerName = marker.lastPathComponent

        chooseCurrentSessionDirectoryMode()

        // cd the seeded session into the marker dir (over the socket, no GUI focus needed), then wait for
        // the tree to report the new cwd (OSC 7 fires on the next prompt after cd).
        let seededID = try activeSessionID()
        _ = try sendCommand(typeRequest(text: "cd \(marker.path)\n", target: seededID, select: true))
        XCTAssertTrue(poll(timeout: 15) {
            (try? self.sendCommand(#"{"cmd":"tree"}"#)).flatMap { self.sessionCwd($0, id: seededID) }?.contains(markerName) ?? false
        }, "the seeded session's cwd should update to the marker dir after cd")
        return (seededID, marker, markerName)
    }

    /// Asserts a second session was created and its cwd equals the seeded (marker) cwd, not home.
    private func assertNewSessionInherited(seededID: String, markerName: String) {
        var newCwd = ""
        var seededCwd = ""
        XCTAssertTrue(poll(timeout: 15) {
            guard let resp = try? self.sendCommand(#"{"cmd":"tree"}"#) else { return false }
            let sessions = self.allSessions(resp)
            guard sessions.count == 2,
                  let created = sessions.first(where: { ($0["id"] as? String) != seededID }),
                  let cwd = created["cwd"] as? String, !cwd.isEmpty else { return false }
            newCwd = cwd
            seededCwd = self.sessionCwd(resp, id: seededID) ?? ""
            return true
        }, "a second session should be created")

        XCTAssertTrue(newCwd.contains(markerName),
                      "the new session should inherit the current session's cwd (\(markerName)), not home; got \(newCwd)")
        XCTAssertEqual(newCwd, seededCwd, "the new session's cwd should equal the current session's cwd")
    }

    /// Opens Settings ▸ General and picks "Current session's directory" in the new-session directory
    /// picker, retrying the tab click each tick (a half-open Settings window can drop the first click).
    /// Settings is left OPEN on purpose: ⌘W is Close Session in agterm (it would kill the seeded
    /// session), and `activeStore` tracks the frontmost TERMINAL window (not the key window), so the
    /// later New Session still targets the main window with Settings floating above it.
    private func chooseCurrentSessionDirectoryMode() {
        let picker = app.descendants(matching: .any).matching(identifier: "settings-new-session-directory").firstMatch
        let general = app.buttons["General"].firstMatch
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if picker.exists, picker.isHittable { break }
            if general.exists, general.isHittable { general.click() } else { app.typeKey(",", modifierFlags: .command) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(picker.exists && picker.isHittable, "the new-session directory picker should be reachable")
        picker.click()
        let choice = app.menuItems["Current session's directory"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "the picker should list the new-session directory modes")
        choice.click()
    }

    /// Every session across every workspace in a `tree` response.
    private func allSessions(_ response: [String: Any]) -> [[String: Any]] {
        guard let result = response["result"] as? [String: Any],
              let tree = result["tree"] as? [String: Any],
              let workspaces = tree["workspaces"] as? [[String: Any]] else { return [] }
        return workspaces.flatMap { ($0["sessions"] as? [[String: Any]]) ?? [] }
    }

    /// The `cwd` of the session with `id` in a `tree` response, or nil if absent.
    private func sessionCwd(_ response: [String: Any], id: String) -> String? {
        allSessions(response).first { ($0["id"] as? String) == id }?["cwd"] as? String
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }
}
