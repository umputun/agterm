import XCTest

/// Drives the Settings window (Cmd+,): confirms the six tabs exist and that choosing a theme in
/// Appearance persists to the hermetic `settings.json` (file oracle, like the other UI tests).
@MainActor
final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["AGTERM_STATE_DIR"] = stateDir.path
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForHittable(timeout: 20), "seeded session should be hittable")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testSettingsWindowHasSixTabsAndThemePersists() throws {
        app.typeKey(",", modifierFlags: .command)

        for tab in ["General", "Appearance", "Interface", "Notifications", "Agent Status", "Key Mapping"] {
            XCTAssertTrue(app.buttons[tab].firstMatch.waitForHittable(timeout: 12), "Settings should have a \(tab) tab")
        }

        let themePicker = settingsControl(tab: "Appearance", control: "settings-theme")
        themePicker.click()
        let choice = app.menuItems["Alabaster"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "the theme menu should list themes")
        choice.click()

        XCTAssertTrue(poll { self.settingsValue("theme") == "Alabaster" }, "the chosen theme should persist to settings.json")
    }

    func testWindowOpacitySliderPersists() throws {
        let opacity = settingsControl(tab: "Appearance", control: "settings-bg-opacity")
        opacity.adjust(toNormalizedSliderPosition: 0.5)

        XCTAssertTrue(poll { (self.settingsDouble("backgroundOpacity") ?? 1) < 1 },
                      "moving the opacity slider should persist a sub-1 backgroundOpacity to settings.json")
    }

    func testNotificationsTogglePersists() throws {
        // type-agnostic match (a grouped-Form Toggle surfaces as a switch/checkbox depending on macOS)
        let toggle = settingsControl(tab: "Notifications", control: "settings-notifications")
        toggle.click() // turn it off (default on)

        XCTAssertTrue(poll { self.settingsBool("notificationsEnabled") == false },
                      "turning notifications off should persist notificationsEnabled=false")
    }

    func testDockBouncePickerPersists() throws {
        let picker = settingsControl(tab: "Notifications", control: "settings-dock-bounce")

        picker.click()
        let untilFocused = app.menuItems["Until focused"]
        XCTAssertTrue(untilFocused.waitForExistence(timeout: 5), "the dock-bounce picker should offer 'Until focused'")
        untilFocused.click()
        XCTAssertTrue(poll { self.settingsValue("dockBounce") == "untilFocused" },
                      "selecting 'Until focused' should persist dockBounce=untilFocused to settings.json")

        picker.click()
        let once = app.menuItems["Once"]
        XCTAssertTrue(once.waitForExistence(timeout: 5), "the dock-bounce picker should offer 'Once'")
        once.click()
        XCTAssertTrue(poll { self.settingsValue("dockBounce") == "once" },
                      "selecting 'Once' should persist dockBounce=once to settings.json")

        picker.click()
        let none = app.menuItems["None"]
        XCTAssertTrue(none.waitForExistence(timeout: 5), "the dock-bounce picker should offer 'None'")
        none.click()
        XCTAssertTrue(poll { self.settingsValue("dockBounce") == nil },
                      "selecting None (the default) should remove the dockBounce key from settings.json")
    }

    func testNotificationSoundPickerPersists() throws {
        let picker = settingsControl(tab: "Notifications", control: "settings-notification-sound")

        picker.click()
        let glass = app.menuItems["Glass"]
        XCTAssertTrue(glass.waitForExistence(timeout: 5), "the notification-sound picker should offer 'Glass'")
        glass.click()
        XCTAssertTrue(poll { self.settingsValue("notificationSoundName") == "Glass" },
                      "selecting 'Glass' should persist notificationSoundName=Glass to settings.json")

        picker.click()
        let none = app.menuItems["None"]
        XCTAssertTrue(none.waitForExistence(timeout: 5), "the notification-sound picker should offer 'None'")
        none.click()
        XCTAssertTrue(poll { self.settingsValue("notificationSoundName") == nil },
                      "selecting None (the default) should remove the notificationSoundName key from settings.json")
    }

    // split off the persistence flow deliberately: a layout failure here would otherwise mask every
    // persistence leg.
    func testAgentStatusShapePickerRowLayoutAndOptions() throws {
        let picker = settingsControl(tab: "Agent Status", control: "settings-status-shape-blocked")

        // the Sound picker is the flush-right reference: every sibling section's trailing control ends
        // at the tab's right margin.
        let soundPicker = settingsControl(tab: "Agent Status", control: "settings-status-blocked-sound")
        assertGlyphRowsLineUp(against: soundPicker, context: "default shapes")

        // Capsule is the widest silhouette and a menu button sizes to its glyph, so a too-narrow or
        // non-trailing column only knocks the row out of line here.
        picker.click()
        let capsuleOption = app.menuItems["Capsule"]
        XCTAssertTrue(capsuleOption.waitForExistence(timeout: 5), "the shape picker should offer 'Capsule'")
        capsuleOption.click()
        XCTAssertTrue(poll { self.settingsValue("blockedStatusShape") == "capsule" },
                      "selecting 'Capsule' should reach the Blocked row before its geometry is measured")
        assertGlyphRowsLineUp(against: soundPicker, context: "Blocked row on the widest silhouette")

        XCTAssertTrue(app.buttons["settings-status-reset"].firstMatch.waitForHittable(timeout: 5),
                      "the Reset button should stay reachable without scrolling")

        // the options are symbols only; each keeps its shape name for VoiceOver, which is what these
        // menu-item lookups match on.
        picker.click()
        let triangle = app.menuItems["Triangle"]
        XCTAssertTrue(triangle.waitForExistence(timeout: 5), "the shape picker should offer 'Triangle'")
        for shape in ["Circle", "Square", "Diamond", "Capsule", "Star"] {
            XCTAssertTrue(app.menuItems[shape].exists, "the shape picker should offer '\(shape)'")
        }
        XCTAssertEqual(picker.menuItems.count, 6, "the six shapes should be the whole option list")
        XCTAssertFalse(app.menuItems["Default"].exists, "the shape picker should no longer offer a 'Default' entry")
        app.typeKey(.escape, modifierFlags: []) // leave the popup closed, the option list picks nothing
    }

    func testAgentStatusShapePickerPersists() throws {
        let picker = settingsControl(tab: "Agent Status", control: "settings-status-shape-blocked")
        let activeShape = settingsControl(tab: "Agent Status", control: "settings-status-shape-active")

        picker.click()
        let triangle = app.menuItems["Triangle"]
        XCTAssertTrue(triangle.waitForExistence(timeout: 5), "the shape picker should offer 'Triangle'")
        triangle.click()
        XCTAssertTrue(poll { self.settingsValue("blockedStatusShape") == "triangle" },
                      "selecting 'Triangle' should persist blockedStatusShape=triangle to settings.json")

        // a second status through the same flow: a copy-pasted binding driving the wrong status only
        // shows up once two rows are exercised.
        activeShape.click()
        let star = app.menuItems["Star"]
        XCTAssertTrue(star.waitForExistence(timeout: 5), "the active shape picker should offer 'Star'")
        star.click()
        XCTAssertTrue(poll { self.settingsValue("activeStatusShape") == "star" },
                      "selecting 'Star' on the Active row should persist activeStatusShape=star to settings.json")
        XCTAssertEqual(settingsValue("blockedStatusShape"), "triangle", "the Active row must not rewrite the Blocked shape")

        app.terminate()
        app.launchForUITest()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForHittable(timeout: 20), "seeded session should be hittable")
        let restored = settingsControl(tab: "Agent Status", control: "settings-status-shape-blocked")
        XCTAssertTrue(poll { (restored.value as? String) == "Triangle" },
                      "after a relaunch the shape picker should show the stored Triangle, got \(String(describing: restored.value))")
        let restoredActive = app.descendants(matching: .any).matching(identifier: "settings-status-shape-active").firstMatch
        XCTAssertTrue(poll { (restoredActive.value as? String) == "Star" },
                      "after a relaunch the Active picker should show the stored Star, got \(String(describing: restoredActive.value))")

        restored.click()
        let fallback = app.menuItems["Circle"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5), "the shape picker should offer 'Circle'")
        fallback.click()
        XCTAssertTrue(poll { self.settingsObject()?["blockedStatusShape"] == nil },
                      "selecting Circle (the default) should remove the blockedStatusShape key from settings.json")
        XCTAssertEqual(settingsValue("activeStatusShape"), "star", "clearing the Blocked shape must leave the Active one alone")

        // without this leg, a resetAgentStatus() missing its three shape-clearing lines ships green.
        let reset = app.buttons["settings-status-reset"].firstMatch
        XCTAssertTrue(reset.waitForHittable(timeout: 5), "the Reset button should be clickable")
        reset.click()
        XCTAssertTrue(poll { self.settingsObject()?["activeStatusShape"] == nil },
                      "Reset to defaults should clear activeStatusShape out of settings.json")
        XCTAssertTrue(poll { (restoredActive.value as? String) == "Circle" },
                      "after the reset the Active picker should fall back to Circle, got \(String(describing: restoredActive.value))")
    }

    func testToolbarModePickerPersists() throws {
        // compact is the default and maps back to nil; Normal/Hidden write a stable key.
        let picker = settingsControl(tab: "Appearance", control: "settings-toolbar-mode")

        picker.click()
        let hidden = app.menuItems["Hidden"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 5), "the toolbar dropdown should offer a Hidden item")
        hidden.click()
        XCTAssertTrue(poll { self.settingsValue("toolbarMode") == "hidden" },
                      "selecting Hidden should persist toolbarMode=hidden to settings.json")

        picker.click()
        let compact = app.menuItems["Compact"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5), "the toolbar dropdown should offer a Compact item")
        compact.click()
        XCTAssertTrue(poll { self.settingsValue("toolbarMode") == nil },
                      "selecting Compact (the default) should remove the toolbarMode key from settings.json")

        picker.click()
        let normal = app.menuItems["Normal"]
        XCTAssertTrue(normal.waitForExistence(timeout: 5), "the toolbar dropdown should offer a Normal item")
        normal.click()
        XCTAssertTrue(poll { self.settingsValue("toolbarMode") == "normal" },
                      "selecting Normal should persist toolbarMode=normal to settings.json")
    }

    func testRestoreRunningCommandTogglePersists() throws {
        let toggle = settingsControl(tab: "General", control: "settings-restore-running-command")
        toggle.click() // turn it on (default off)

        XCTAssertTrue(poll { self.settingsBool("restoreRunningCommand") == true },
                      "turning restore-running-commands on should persist restoreRunningCommand=true")
    }

    func testConfirmCloseSessionTogglePersists() throws {
        let toggle = settingsControl(tab: "General", control: "settings-confirm-close-session")
        toggle.click() // turn it on (default off)

        XCTAssertTrue(poll { self.settingsBool("confirmCloseSession") == true },
                      "turning confirm-before-closing on should persist confirmCloseSession=true")
    }

    func testWorkspaceRowClickExpandsTogglePersists() throws {
        let toggle = settingsControl(tab: "General", control: "settings-workspace-row-click-expands")
        toggle.click() // turn it off (default on)

        XCTAssertTrue(poll { self.settingsBool("workspaceRowClickExpands") == false },
                      "turning row-click expansion off should persist workspaceRowClickExpands=false")
    }

    func testNewSessionDirectoryPickerPersists() throws {
        let picker = settingsControl(tab: "General", control: "settings-new-session-directory")
        picker.click()
        let choice = app.menuItems["Current session's directory"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "the picker should list the new-session directory modes")
        choice.click()

        XCTAssertTrue(poll { self.settingsValue("newSessionDirectory") == "currentSession" },
                      "choosing current-session should persist newSessionDirectory=currentSession to settings.json")
    }

    func testScrollSpeedSliderPersists() throws {
        let slider = settingsControl(tab: "General", control: "settings-scroll-speed")
        slider.adjust(toNormalizedSliderPosition: 1.0) // drag to max (10), away from the default 3

        XCTAssertTrue(poll { (self.settingsDouble("mouseScrollMultiplier") ?? 3) > 3 },
                      "moving the scroll-speed slider should persist a >3 mouseScrollMultiplier to settings.json")
    }

    func testInterfaceElementTogglePersists() throws {
        // the Interface tab's toggles are default-on (element visible).
        let toggle = settingsControl(tab: "Interface", control: "settings-interface-split")
        toggle.click()
        XCTAssertTrue(poll { self.settingsStringArray("hiddenInterfaceElements")?.contains("split") == true },
                      "hiding the Split view element should persist \"split\" into hiddenInterfaceElements")

        toggle.click()
        XCTAssertTrue(poll { self.settingsObject()?["hiddenInterfaceElements"] == nil },
                      "re-showing the last hidden element should remove hiddenInterfaceElements from settings.json")
    }

    func testCommandWClosesTheSettingsWindowNotTheSession() throws {
        // #401: close_session owns ⌘W app-wide, so ⌘W over Settings reached the deck behind it.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(poll { self.sessionRowCount() == 2 }, "⌘N should add a second session")

        let control = settingsControl(tab: "General", control: "settings-confirm-close-session")

        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(poll({ !control.exists }, timeout: 10), "⌘W should close the Settings window")
        // both rows still readable is also the window-survival oracle: they render inside it.
        XCTAssertEqual(sessionRowCount(), 2, "⌘W over Settings must leave the terminal sessions alone")
    }

    // MARK: - Helpers

    /// Opens the Settings window (Cmd+,) if needed, switches to `tab`, and returns the control with
    /// `control` id once it is hittable — RETRYING the tab click each tick. A stale Settings window
    /// (restored from a prior test on a different tab) can be half-open or non-key when the first
    /// click lands, silently dropping it so the tab never switches and the control never renders;
    /// retrying until the control is actually hittable is robust to that.
    @discardableResult
    private func settingsControl(tab: String, control: String, timeout: TimeInterval = 12,
                                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = app.descendants(matching: .any).matching(identifier: control).firstMatch
        let tabButton = app.buttons[tab].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists, target.isHittable { return target }
            if tabButton.exists, tabButton.isHittable {
                tabButton.click()
            } else {
                app.typeKey(",", modifierFlags: .command) // settings not open yet (or lost) — (re)open
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Settings '\(tab)' control '\(control)' never became hittable", file: file, line: line)
        return target
    }

    /// Asserts the three Agent Status glyph rows are laid out as one block: each row's color well and
    /// shape picker share a row, every shape picker ends flush with `reference` (a sibling section's
    /// trailing control, so the tab has no ragged right edge and the pickers form one column), and the
    /// color wells share a leading edge. Every check is control-vs-control, never an absolute coordinate —
    /// the offsets themselves move with any Form-style, font or OS-metric change, these relationships
    /// must not. `context` names the state being measured so a failure says which one broke.
    private func assertGlyphRowsLineUp(against reference: XCUIElement, context: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        var wellLeadingEdges: [CGFloat] = []
        for status in ["active", "blocked", "completed"] {
            let well = app.descendants(matching: .any).matching(identifier: "settings-status-\(status)").firstMatch
            let shape = app.descendants(matching: .any).matching(identifier: "settings-status-shape-\(status)").firstMatch
            XCTAssertTrue(well.waitForHittable(timeout: 5), "the \(status) color well should be on this tab (\(context))",
                          file: file, line: line)
            XCTAssertTrue(shape.frame.minY <= well.frame.midY && well.frame.midY <= shape.frame.maxY,
                          "the \(status) color well and shape picker should sit on the same row (\(context))",
                          file: file, line: line)
            XCTAssertEqual(shape.frame.maxX, reference.frame.maxX, accuracy: 1,
                           "the \(status) shape picker should end flush with the reference control (\(context))",
                           file: file, line: line)
            wellLeadingEdges.append(well.frame.minX)
        }
        for edge in wellLeadingEdges.dropFirst() {
            XCTAssertEqual(edge, wellLeadingEdges[0], accuracy: 1,
                           "the color wells should stack in one column (\(context))", file: file, line: line)
        }
    }

    private func sessionRowCount() -> Int {
        app.staticTexts.matching(identifier: "session-row").count
    }

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }

    private func settingsValue(_ key: String) -> String? {
        settingsObject()?[key] as? String
    }

    private func settingsBool(_ key: String) -> Bool? {
        (settingsObject()?[key] as? NSNumber)?.boolValue
    }

    private func settingsDouble(_ key: String) -> Double? {
        (settingsObject()?[key] as? NSNumber)?.doubleValue
    }

    private func settingsStringArray(_ key: String) -> [String]? {
        settingsObject()?[key] as? [String]
    }

    private func settingsObject() -> [String: Any]? {
        let file = stateDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
