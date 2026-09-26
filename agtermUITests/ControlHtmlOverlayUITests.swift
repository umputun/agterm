import XCTest

@MainActor
final class ControlHtmlOverlayUITests: ControlAPITestCase {
    private var pageDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        pageDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-html-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        try writePage("a.html", title: "Artifact A",
                      body: #"<p>hello artifact</p><a href="b.html">next page</a><input aria-label="field">"#)
        try writePage("b.html", title: "Artifact B", body: "<p>second page</p>")
    }

    override func tearDown() async throws {
        if let pageDir { try? FileManager.default.removeItem(at: pageDir) }
        try await super.tearDown()
    }

    func testPageRendersRefusesProgramReadsAndClosesWithCommandW() throws {
        let id = try activeSessionID()
        let open = try sendCommand(openRequest(id))
        XCTAssertEqual(open["ok"] as? Bool, true, "html open should succeed: \(open)")
        XCTAssertTrue(pollPage(id: id) { $0["state"] as? String == "loaded" && $0["title"] as? String == "Artifact A" },
                      "the page should load and report its title")
        XCTAssertTrue(app.webViews.staticTexts["hello artifact"].waitForExistence(timeout: 10), "the page should render")

        let result = try sendCommand(#"{"cmd":"session.overlay.result","target":"\#(id)"}"#)
        XCTAssertEqual(result["error"] as? String, "no overlay result: the slot holds an html page", "\(result)")
        let text = try sendCommand(#"{"cmd":"session.overlay.text","target":"\#(id)"}"#)
        XCTAssertEqual(text["error"] as? String, "no overlay to read: the slot holds an html page", "\(text)")

        app.activate()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(pollOverlay(id: id, expected: false), "⌘W should close the page")
        XCTAssertTrue(pollSessionRowCount(1, timeout: 10), "⌘W must not close the session behind the page")
    }

    func testWithoutNavigationThePageHasOnlyAFloatingCloseButton() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(openRequest(id))["ok"] as? Bool, true)
        XCTAssertTrue(app.webViews.staticTexts["hello artifact"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["htmlOverlay.back"].exists, "no toolbar without --navigation")
        app.buttons["htmlOverlay.close"].click()
        XCTAssertTrue(pollOverlay(id: id, expected: false), "the floating close button should close the page")
    }

    func testToolbarAndControlNavigateTheSameHistory() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(openRequest(id, navigation: true))["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: self.sessionTreeNode(id).flatMap { ($0["htmlOverlays"] as? [[String: Any]])?.first?["navigation"] as? Bool } == true,
                           timeout: 10), "the tree should report the toolbar")
        let link = app.webViews.links["next page"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the link should render")
        link.click()
        XCTAssertTrue(pollPage(id: id) { ($0["page"] as? String)?.hasSuffix("/b.html") == true && $0["canGoBack"] as? Bool == true },
                      "clicking a link inside the grant should navigate in place")

        app.buttons["htmlOverlay.back"].click()
        XCTAssertTrue(pollPage(id: id) { ($0["page"] as? String)?.hasSuffix("/a.html") == true }, "the toolbar back button should step back")

        let forward = try sendCommand(#"{"cmd":"session.overlay.navigate","target":"\#(id)","args":{"to":"forward"}}"#)
        XCTAssertEqual(forward["ok"] as? Bool, true, "navigate forward should succeed: \(forward)")
        XCTAssertTrue(pollPage(id: id) { ($0["page"] as? String)?.hasSuffix("/b.html") == true }, "navigate forward should step forward")

        let reload = try sendCommand(#"{"cmd":"session.overlay.reload","target":"\#(id)"}"#)
        XCTAssertEqual(reload["ok"] as? Bool, true, "reload should succeed: \(reload)")
        XCTAssertTrue(pollPage(id: id) { ($0["page"] as? String)?.hasSuffix("/a.html") == true && $0["state"] as? String == "loaded" },
                      "reload without --current should load the original file again")

        app.buttons["htmlOverlay.close"].click()
        XCTAssertTrue(pollOverlay(id: id, expected: false), "the toolbar close button should close the page")
    }

    func testClickingAPanePageTakesSplitFocusAndCommandWClosesThatPage() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(try pollSplit(id, timeout: 10), "the split should be shown")
        let focusLeft = try sendCommand(#"{"cmd":"session.focus","target":"\#(id)","args":{"pane":"left"}}"#)
        XCTAssertEqual(focusLeft["ok"] as? Bool, true, "\(focusLeft)")
        XCTAssertTrue(try pollSplitFocused(id, expected: false, timeout: 10))

        XCTAssertEqual(try sendCommand(openRequest(id, pane: "right"))["ok"] as? Bool, true)
        let text = app.webViews.staticTexts["hello artifact"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "the pane page should render")
        XCTAssertTrue(try pollSplitFocused(id, expected: false, timeout: 3), "opening on the unfocused pane must not move focus")

        text.click()
        XCTAssertTrue(try pollSplitFocused(id, expected: true, timeout: 10), "clicking the pane page should focus its pane")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(pollPaneOverlays(id: id, expected: []), "⌘W should close the focused pane's page")
        XCTAssertTrue(try pollSplit(id, timeout: 10), "⌘W must not collapse the split under the page")
    }

    func testABackgroundOpenLeavesTheKeyboardWithTheActiveTerminal() throws {
        let background = try activeSessionID()
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        let active = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(pollActiveSessionID(try XCTUnwrap(UUID(uuidString: active)), timeout: 10))

        XCTAssertEqual(try sendCommand(openRequest(background))["ok"] as? Bool, true)
        XCTAssertTrue(pollPage(id: background) { $0["file"] != nil }, "the background page should be open")

        app.activate()
        let marker = pageDir.appendingPathComponent("typed")
        XCTAssertNotNil(keyboardTypeUntilMarker("echo typed > '\(marker.path)'", file: marker),
                        "typing should still reach the active session's terminal")
    }

    func testFocusReturnsToThePageAfterThePaletteCloses() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(openRequest(id))["ok"] as? Bool, true)
        let field = app.webViews.textFields["field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the page's field should render")
        field.click()

        app.menuBars.menuBarItems["Navigate"].click()
        let palette = app.menuItems["Command Palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5), "Navigate menu should offer the palette")
        palette.click()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "the palette should open")
        app.typeKey(.escape, modifierFlags: [])

        app.typeText("abc")
        XCTAssertTrue(poll(until: (field.value as? String ?? "").contains("abc"), timeout: 5),
                      "keystrokes after the palette closes should reach the page")
    }

    func testAFloatingPageRendersResizesAndClosesLikeAProgramOverlay() throws {
        let id = try activeSessionID()
        let file = pageDir.appendingPathComponent("a.html").path
        let open = try sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"html":"\#(file)","sizePercent":60}}"#)
        XCTAssertEqual(open["ok"] as? Bool, true, "a floating html open should succeed: \(open)")
        XCTAssertTrue(app.webViews.staticTexts["hello artifact"].waitForExistence(timeout: 10), "the floating page should render")
        XCTAssertTrue(poll(until: self.sessionTreeNode(id)?["overlaySizePercent"] as? Int == 60, timeout: 10))
        let window = app.windows.firstMatch.frame
        let floating = app.webViews.firstMatch.frame
        XCTAssertLessThan(floating.width, window.width * 0.7, "a 60% page should not span the window")

        let grow = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"sizePercent":80}}"#)
        XCTAssertEqual(grow["ok"] as? Bool, true, "\(grow)")
        XCTAssertTrue(poll(until: self.sessionTreeNode(id)?["overlaySizePercent"] as? Int == 80, timeout: 10))
        XCTAssertTrue(poll(until: app.webViews.firstMatch.frame.width > floating.width + 20, timeout: 10),
                      "resizing should grow the page without reloading it away")
        let full = try sendCommand(#"{"cmd":"session.overlay.resize","target":"\#(id)","args":{"full":true}}"#)
        XCTAssertEqual(full["ok"] as? Bool, true, "\(full)")
        XCTAssertTrue(poll(until: self.sessionTreeNode(id)?["overlaySizePercent"] == nil, timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["hello artifact"].exists, "the page should survive the resizes")

        app.activate()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(pollOverlay(id: id, expected: false), "⌘W should close the page")
    }

    func testTheBackingShowsUnderAnUnstyledPageAndAnAuthoredBodyCoversIt() throws {
        let id = try activeSessionID()
        try writePage("plain.html", title: "Plain", body: "<p>plain page</p>")
        try writePage("white.html", title: "White", body: "<style>body { background: white }</style><p>white page</p>")

        let plain = pageDir.appendingPathComponent("plain.html").path
        XCTAssertEqual(try sendCommand(##"{"cmd":"session.overlay.open","target":"\##(id)","args":{"html":"\##(plain)","color":"#c02040"}}"##)["ok"] as? Bool, true)
        XCTAssertTrue(app.webViews.staticTexts["plain page"].waitForExistence(timeout: 10))
        let backing = try bottomPixel(of: app.webViews.firstMatch)
        XCTAssertEqual(backing.redComponent, 0xC0 / 255.0, accuracy: 0.08, "the --background-color backing should show: \(backing)")
        XCTAssertEqual(backing.blueComponent, 0x40 / 255.0, accuracy: 0.08, "\(backing)")
        XCTAssertTrue(try sendCommand(#"{"cmd":"session.overlay.close","target":"\#(id)"}"#)["ok"] as? Bool == true)

        let white = pageDir.appendingPathComponent("white.html").path
        XCTAssertEqual(try sendCommand(##"{"cmd":"session.overlay.open","target":"\##(id)","args":{"html":"\##(white)","color":"#c02040"}}"##)["ok"] as? Bool, true)
        XCTAssertTrue(app.webViews.staticTexts["white page"].waitForExistence(timeout: 10))
        let page = try bottomPixel(of: app.webViews.firstMatch)
        XCTAssertGreaterThan(page.blueComponent, 0.9, "an authored body background should fill the viewport: \(page)")
    }

    func testAnAskOverAPageKeepsTheKeyboardWhenFocusIsRestored() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(openRequest(id))["ok"] as? Bool, true)
        let field = app.webViews.textFields["field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the page's field should render")
        field.click()

        let ask = try openAsk([["id": "ok", "label": "OK"]], target: id)
        XCTAssertTrue(askButton("ok").waitForExistence(timeout: 10), "the ask should show over the page")
        app.menuBars.menuBarItems["Navigate"].click()
        let palette = app.menuItems["Command Palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.click()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(ask)["id"] as? String, "ok", "Return after the palette should answer the ask")
        XCTAssertEqual(field.value as? String ?? "", "", "no keystroke may reach the page behind the ask")
    }

    func testClickingASessionPageBesideAPaneAskKeepsTheKeyboardAfterThePalette() throws {
        let id = try activeSessionID()
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.split","target":"\#(id)","args":{"mode":"on"}}"#)["ok"] as? Bool, true)
        XCTAssertTrue(try pollSplit(id, timeout: 10), "the split should be shown")
        XCTAssertEqual(try sendCommand(openRequest(id))["ok"] as? Bool, true)
        let field = app.webViews.textFields["field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the page's field should render")

        let ask = try openAsk([["id": "ok", "label": "OK"]], target: id, options: ["pane": "right"])
        XCTAssertTrue(askButton("ok").waitForExistence(timeout: 10), "the pane ask should show over the page")
        field.click()
        app.typeText("abc")
        XCTAssertTrue(poll(until: (field.value as? String ?? "").contains("abc"), timeout: 5),
                      "a click on the page beside the ask should give the page the keyboard")

        app.menuBars.menuBarItems["Navigate"].click()
        let palette = app.menuItems["Command Palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.click()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        app.typeText("xyz")
        XCTAssertTrue(poll(until: (field.value as? String ?? "").contains("abcxyz"), timeout: 5),
                      "the page should keep the keyboard after the palette closes: \(field.value ?? "nil")")
        XCTAssertEqual(try askResult(ask)["result"] as? String, "pending")
    }

    func testAUrlPageRendersClosesWithCommandWAndARefusedOneShowsTheError() throws {
        let id = try activeSessionID()
        try writePage("served.html", title: "Served", body: "<p>served page</p>")
        let port = Int.random(in: 40000..<60000)
        let server = #"/usr/bin/python3 -m http.server \#(port) --bind 127.0.0.1 --directory \#(pageDir.path)"#
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.new","args":{"command":"\#(server)","noSelect":true}}"#)["ok"] as? Bool, true)
        let served = "http://127.0.0.1:\(port)/served.html"
        XCTAssertTrue(poll(until: (try? Data(contentsOf: URL(string: served)!)) != nil, timeout: 15), "the page server should start")
        let open = { (url: String) in
            try self.sendCommand(#"{"cmd":"session.overlay.open","target":"\#(id)","args":{"url":"\#(url)"}}"#)
        }

        XCTAssertEqual(try open(served)["ok"] as? Bool, true)
        XCTAssertTrue(app.webViews.staticTexts["served page"].waitForExistence(timeout: 10), "the served page should render")
        XCTAssertTrue(pollPage(id: id) { $0["url"] as? String == served && $0["file"] == nil })
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(pollOverlay(id: id, expected: false), "⌘W should close the url page")

        XCTAssertEqual(try open("http://127.0.0.1:\(port + 1)/")["ok"] as? Bool, true)
        XCTAssertTrue(app.descendants(matching: .any)["htmlOverlay.error"].waitForExistence(timeout: 10),
                      "a refused connection should show the error panel")
        XCTAssertTrue(pollPage(id: id) { $0["state"] as? String == "failed" })
    }

    private func bottomPixel(of element: XCUIElement) throws -> NSColor {
        let image = element.screenshot().image
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 12))
        return color.usingColorSpace(.sRGB) ?? color
    }

    private func writePage(_ name: String, title: String, body: String) throws {
        let html = "<!doctype html><html><head><title>\(title)</title></head><body>\(body)</body></html>"
        try html.write(to: pageDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func openRequest(_ id: String, pane: String? = nil, navigation: Bool = false) -> String {
        let file = pageDir.appendingPathComponent("a.html").path
        let paneArg = pane.map { #","pane":"\#($0)""# } ?? ""
        let navigationArg = navigation ? #","navigation":true"# : ""
        return #"{"cmd":"session.overlay.open","target":"\#(id)","args":{"html":"\#(file)","cwd":"\#(pageDir.path)"\#(paneArg)\#(navigationArg)}}"#
    }

    private func sessionTreeNode(_ id: String) -> [String: Any]? {
        guard let tree = try? sendCommand(#"{"cmd":"tree"}"#),
              let result = tree["result"] as? [String: Any], let root = result["tree"] as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]] else { return nil }
        return workspaces.flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            .first { ($0["id"] as? String)?.lowercased() == id.lowercased() }
    }

    private func pollPage(id: String, timeout: TimeInterval = 10, _ matches: @escaping ([String: Any]) -> Bool) -> Bool {
        poll(until: (self.sessionTreeNode(id)?["htmlOverlays"] as? [[String: Any]])?.contains(where: matches) == true,
             timeout: timeout)
    }

    private func pollOverlay(id: String, expected: Bool) -> Bool {
        poll(until: (self.sessionTreeNode(id)?["overlay"] as? Bool ?? false) == expected, timeout: 10)
    }

    private func pollPaneOverlays(id: String, expected: [String]) -> Bool {
        poll(until: (self.sessionTreeNode(id)?["paneOverlays"] as? [String] ?? []) == expected, timeout: 10)
    }
}
