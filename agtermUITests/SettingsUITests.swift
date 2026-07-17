import XCTest

/// Drives the Settings window (Cmd+,): confirms the five tabs exist and that choosing a theme in
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

    func testSettingsWindowHasFiveTabsAndThemePersists() throws {
        app.typeKey(",", modifierFlags: .command)

        // the five tabs are reachable.
        for tab in ["General", "Appearance", "Notifications", "Agent Status", "Key Mapping"] {
            XCTAssertTrue(app.buttons[tab].firstMatch.waitForHittable(timeout: 12), "Settings should have a \(tab) tab")
        }

        // pick a known theme from the theme picker and confirm it lands in settings.json.
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

        // Until focused → dockBounce="untilFocused".
        picker.click()
        let untilFocused = app.menuItems["Until focused"]
        XCTAssertTrue(untilFocused.waitForExistence(timeout: 5), "the dock-bounce picker should offer 'Until focused'")
        untilFocused.click()
        XCTAssertTrue(poll { self.settingsValue("dockBounce") == "untilFocused" },
                      "selecting 'Until focused' should persist dockBounce=untilFocused to settings.json")

        // Once → dockBounce="once".
        picker.click()
        let once = app.menuItems["Once"]
        XCTAssertTrue(once.waitForExistence(timeout: 5), "the dock-bounce picker should offer 'Once'")
        once.click()
        XCTAssertTrue(poll { self.settingsValue("dockBounce") == "once" },
                      "selecting 'Once' should persist dockBounce=once to settings.json")

        // None → the default, mapped back to nil, so the key is REMOVED.
        picker.click()
        let none = app.menuItems["None"]
        XCTAssertTrue(none.waitForExistence(timeout: 5), "the dock-bounce picker should offer 'None'")
        none.click()
        XCTAssertTrue(poll { self.settingsValue("dockBounce") == nil },
                      "selecting None (the default) should remove the dockBounce key from settings.json")
    }

    func testToolbarModePickerPersists() throws {
        // the Toolbar dropdown offers Normal/Compact/Hidden. compact is the default and maps back to nil;
        // Normal/Hidden write a stable key.
        let picker = settingsControl(tab: "Appearance", control: "settings-toolbar-mode")

        // Hidden → toolbarMode="hidden".
        picker.click()
        let hidden = app.menuItems["Hidden"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 5), "the toolbar dropdown should offer a Hidden item")
        hidden.click()
        XCTAssertTrue(poll { self.settingsValue("toolbarMode") == "hidden" },
                      "selecting Hidden should persist toolbarMode=hidden to settings.json")

        // Compact → the default, mapped back to nil, so the key is REMOVED (the nil-mapping branch).
        picker.click()
        let compact = app.menuItems["Compact"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5), "the toolbar dropdown should offer a Compact item")
        compact.click()
        XCTAssertTrue(poll { self.settingsValue("toolbarMode") == nil },
                      "selecting Compact (the default) should remove the toolbarMode key from settings.json")

        // Normal → toolbarMode="normal".
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

    private func settingsObject() -> [String: Any]? {
        let file = stateDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
