import AppKit
import XCTest
import agtermCore

/// Stages and captures the website and README screenshots. Real agents run in them, so the class runs
/// only with `TEST_RUNNER_AGTERM_SCREENSHOTS=1`; captures land in the runner container's
/// `Data/tmp/agterm-shots`, since xcresult attachment export returns stub files.
@MainActor
final class ScreenshotUITests: ControlAPITestCase {
    // a seeded file without a theme reads as nil, Ghostty's built-in theme, not the bundled agterm one
    override var seededSettings: [String: Any]? {
        var settings: [String: Any] = ["restoreMode": "live", "theme": "agterm"]
        if name.contains("testMinimal") { settings.merge(minimalChrome) { $1 } }
        if name.contains("testKeymapEditor"), let shownConfigDir { settings["configDirectory"] = shownConfigDir }
        // banners land outside the window capture and on the desktop of whoever runs the shots
        if name.contains("testNotifications") { settings["notificationsEnabled"] = false }
        return settings
    }

    /// The minimal shot's chrome, seeded because none of it has a control command: no toolbar, every
    /// optional button and icon hidden, no info lines, and every status drawn as a pill.
    private var minimalChrome: [String: Any] {
        ["hiddenInterfaceElements": ["sidebarToggle", "workspaceChevrons", "newWorkspace", "newSession", "flaggedView", "focusFilter", "workspaceAddSession",
                                     "workspaceIcons", "sessionIcons", "recentSessions", "scratch", "split",
                                     "dashboard", "quickTerminal", "sessionContext", "windowName"],
         "sessionInfoDisplay": "off",
         "toolbarMode": "hidden",
         "activeStatusShape": "capsule", "blockedStatusShape": "capsule", "completedStatusShape": "capsule"]
    }
    /// The keymap shot's config directory, which `scripts/screenshots.sh` reserves and removes.
    private var shownConfigDir: String? { ProcessInfo.processInfo.environment["AGTERM_KEYMAP_DIR"] }

    // chat.py starts its peer with `session restart`, which needs Live sessions
    override var enablesZmxForUITest: Bool { true }

    /// The hero frame is 1187x696 pt; split and grid shots use 1.2x the same ratio so a codex status
    /// line fits one pane, and the page scales them down to the frame.
    private let heroSize = (width: 1187, height: 696)
    private let nvimOnTheme = "-c \"hi Normal guibg=NONE | hi NormalNC guibg=NONE | hi SignColumn guibg=NONE | " +
        "hi LineNr guibg=NONE | hi EndOfBuffer guibg=NONE | hi FoldColumn guibg=NONE\""
    private let wideSize = (width: 1424, height: 835)

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["AGTERM_SCREENSHOTS"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_AGTERM_SCREENSHOTS=1 to stage and capture the screenshots")
        }
        try await super.setUp()
        try recordNamespace()
    }

    override func tearDown() async throws {
        var cleanupError: Error?
        do { try recordNamespace() } catch { cleanupError = error }
        do { try reapTestDaemons() } catch { cleanupError = cleanupError ?? error }
        app?.terminate()
        try await super.tearDown()
        if let cleanupError { throw cleanupError }
    }

    /// Claude Code and codex settle a question in one split; the pair's companion tails the agtermCore test
    /// log, and a folded parent beside it shows the stack glyph for its working companion.
    func testPairClaudeCodex() throws {
        let seeded = try activeSessionID()
        try sizeWindow(wideSize)
        try nameSeededWorkspace(seeded, "agterm")

        let topic = """
        /chat codex In agterm, ControlDispatcher returns nil for commands it has not migrated, so the app's \
        own switch handles them. Which commands still take that path, and which one is worth migrating next? \
        This is read-only: no edits, no commits, no questions to me. Settle it with codex, then finish with \
        one short paragraph whose first word is Conclusion, followed by a colon; keep that word out of your messages to the peer. Write file paths relative to \
        the repository root and include no links or commit hashes.
        """
        let pair = try row("control api", in: "agterm", command: agentCommand("claude", prompt: topic), select: true)
        try ctl("session", "context", "which control commands still fall back to the app's own switch", "--target", pair)
        try ctl("session", "close", "--target", seeded)
        let tests = try row("core tests", parent: pair, command: "/usr/bin/tail -n 80 -f \(coreTestLog)",
                            info: "✅ **\(coreTestCount)** ^[passed](color: \"green\")")
        try ctl("session", "status", "completed", "--shape", "checkmark", "--target", tests)
        let release = try row("release notes", in: "agterm", info: "📦 **14** entries ^[drafted](color: \"green\")")
        let check = try row("changelog check", parent: release, info: "^[3 of 14 checked](color: \"teal\")")
        try ctl("session", "status", "active", "--target", check)
        try ctl("session", "collapse", "--target", release)
        try row("dispatcher docs", in: "agterm", info: "🌿 **dispatcher-docs** ^[● 2](color: \"orange\")")

        XCTAssertTrue(poll(until: self.chatConcluded(pair), timeout: 900), "Claude should reach its verdict with codex")
        try readyFrame()
        try capture("pair-codex", size: wideSize)
    }

    /// The least chrome agterm draws: one pane, session names and pill statuses, nothing else.
    func testMinimal() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")

        let question = """
        In agterm, how does a URL page in the HTML overlay stay on the origin it was opened with? Answer in \
        at most six short bullets, after a first line whose first word is Answer, followed by a colon. This \
        is read-only: no edits, no commits, no questions to me. Write file paths relative to the repository \
        root and include no links or commit hashes.
        """
        let agent = try row("overlay origin", in: "agterm", command: agentCommand("claude", prompt: question), select: true)
        try ctl("session", "close", "--target", seeded)
        try row("page zoom", in: "agterm")
        let links = try row("link routing", in: "agterm")
        try ctl("session", "status", "completed", "--target", links)
        try row("markdown pages", in: "overlay docs")
        try row("text pages", in: "overlay docs")

        XCTAssertTrue(poll(until: self.turnEnded(agent) && self.paneOpensLine(agent, "Answer:"), timeout: 600),
                      "Claude should finish its answer")
        try readyFrame()
        try capture("minimal", size: heroSize)
    }

    /// The leader-i attention page reopened over its triage session, beside the reviews earlier presses
    /// started as its companions, one per item the page lists.
    func testAttentionPage() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try ctl("theme", "set", "TokyoNight Storm")
        try nameSeededWorkspace(seeded, "agterm")

        let script = "/Users/umputun/.config/agterm/scripts/attention.py"
        let command = "/bin/zsh -c 'source /Users/umputun/.dot-files/zsh/ump-dev.rc; " +
            "AGT_SESSION_ID=$AGTERM_SESSION_ID AGT_SOCKET=$AGTERM_SOCKET AGT_WINDOW_ID=$AGTERM_WINDOW_ID " +
            "GHA_JUDGE=jev \(script)'"
        let triage = try row("triage", in: "agterm", command: command, select: true)
        try ctl("session", "context", "open issues, pull requests and discussions on agterm", "--target", triage)
        try ctl("session", "close", "--target", seeded)
        try row("#1088 open rules", parent: triage)
        try row("#963 rerun restore", parent: triage)
        try row("#800 undo grace", parent: triage)

        // section titles only the Repo view draws: the header names the repo in the Backlog fallback too
        XCTAssertTrue(poll(until: self.pageShows(triage, "Needs you") || self.pageShows(triage, "Waiting on contributor"),
                           timeout: 600), "the attention page should render its Repo view")
        // the companions name items the page must still list; live data can drop one between runs
        for item in ["#1088", "#963", "#800"] {
            XCTAssertTrue(pageShows(triage, item), "the attention page no longer lists \(item)")
        }
        try readyFrame()
        try capture("attention-page", size: heroSize)
    }

    /// The annotate-document recipe reviewing the top-level sessions plan, with top-level sessions in the
    /// sidebar above the named workspace that implements it.
    func testAnnotateDocument() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")

        let script = "\(repoRoot)/cookbook/annotate-document/scripts/webrev.py"
        // the page id the script prints to stderr would show above the floating panel
        let command = "/bin/zsh -lc '\(script) review docs/plans/completed/20261120-top-level-sessions.md " +
            "2>>\(markerDir.path)/webrev.log'"
        let review = try row("plan review", in: "root", command: command, select: true)
        try ctl("session", "context", "top-level sessions plan, before implementation", "--target", review)
        try ctl("session", "close", "--target", seeded)
        try row("scratchpad", in: "root")
        try row("top-level sessions", in: "agterm", info: "🌿 **top-level** ^[● 4](color: \"orange\") ^[↑3](color: \"blue\")")

        XCTAssertTrue(poll(until: self.pageShows(review, "Top-Level Sessions Outside Workspaces"), timeout: 60),
                      "the review page should render: \(webrevLog)")
        try readyFrame()
        let saved = "how does undo put a closed session back into the root"
        try annotate(block: "Internally every such session belongs", note: saved)
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(poll(until: !self.app.webViews.descendants(matching: .textView).firstMatch.exists &&
                           self.pageShows(review, saved), timeout: 10), "the first note should be saved and its editor closed")
        let draft = "the sidebar already says top-level, so maybe just"
        try annotate(block: "User-facing name", note: draft)
        XCTAssertTrue(poll(until: self.app.webViews.descendants(matching: .textView).firstMatch.value as? String == draft, timeout: 5),
                      "the open editor should hold the whole draft")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try capture("annotate-document", size: heroSize)
        try closeReview(review)
    }

    /// The maintainer's webrev diff review of one real agterm commit, opened as a companion of the session
    /// that made the change. The cookbook copy has no diff mode.
    func testWebrevDiff() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try ctl("theme", "set", "Catppuccin Frappe")
        try nameSeededWorkspace(seeded, "agterm")

        let change = try row("split pane refusal", in: "agterm",
                             info: "🌿 **split-refusal** ^[✓](color: \"green\") ^[↑1](color: \"blue\")")
        try ctl("session", "status", "completed", "--shape", "checkmark", "--target", change)
        try ctl("session", "close", "--target", seeded)
        let script = "/Users/umputun/.dot-files/claude/skills/webrev/scripts/webrev.py"
        let command = "/bin/zsh -lc '\(script) diff d01832ff~1 d01832ff " +
            "--title \"control: refuse a missing split pane alike in session and font commands\" " +
            "2>>\(markerDir.path)/webrev.log'"
        let review = try row("review", parent: change, command: command, select: true)
        try ctl("session", "context", "refuse a missing split pane alike in session and font commands", "--target", review)
        try row("commands.html", in: "site", info: "🌿 **split-refusal** ^[● 1](color: \"orange\")")

        XCTAssertTrue(poll(until: self.pageShows(review, "ServerActions+Sessions.swift"), timeout: 60),
                      "the webrev page should render: \(webrevLog)")
        try readyFrame()
        try capture("webrev-diff", size: heroSize)
        try closeReview(review)
    }

    /// Everyday terminal work with no agent: neovim on a source file beside a shell listing the checkout and
    /// its recent history, with lazygit, htop and a docs server as companions and rows.
    func testTerminal() throws {
        let seeded = try activeSessionID()
        try sizeWindow(wideSize)
        try ctl("theme", "set", "Rose Pine Moon")
        try nameSeededWorkspace(seeded, "agterm")

        let edit = try row("html origin", in: "agterm",
                           command: "/bin/zsh -lc 'exec nvim \(nvimOnTheme) +104 agtermCore/Sources/agtermCore/HtmlOverlay.swift'",
                           select: true)
        try ctl("session", "context", "what a URL page counts as its own origin", "--target", edit)
        try ctl("session", "close", "--target", seeded)
        try ctl("session", "split", "on", "--target", edit)
        try ctl("session", "focus", "left", "--target", edit)
        XCTAssertTrue(poll(until: self.paneText(edit, pane: "right", window: nil) != nil, timeout: 30),
                      "the split shell should start")
        try ctl("session", "type", "--target", edit, "--pane", "right",
                "clear; eza -l --git --group-directories-first; git log --graph -8 --decorate-refs=refs/heads/master " +
                "--format='%C(yellow)%h%C(auto)%d %C(reset)%<(44,trunc)%s'\n")
        let lazygit = try row("lazygit", parent: edit, command: "/bin/zsh -lc 'exec lazygit'")
        let htop = try row("htop", parent: edit, command: "/bin/zsh -lc 'exec htop -F agterm'")
        let preview = try row("docs preview", in: "site",
                command: "/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1 --directory site",
                info: "🌐 ^[localhost:8765](color: \"blue\")")

        XCTAssertTrue(poll(until: (self.paneText(edit, pane: "left", window: nil) ?? "").contains("struct HtmlOrigin"),
                           timeout: 30), "neovim should show the file")
        XCTAssertTrue(poll(until: { let text = self.paneText(edit, pane: "right", window: nil) ?? ""
            return text.contains("Makefile") && text.contains("(master)") }(), timeout: 30),
                      "the listing and the history should draw")
        try readyFrame()
        for (name, id) in [("lazygit", lazygit), ("htop", htop), ("docs preview", preview)] {
            XCTAssertNotNil(try sessionNodeIfPresent(id: id)?["foreground"], "\(name) should still be running")
        }
        try capture("terminal", size: wideSize)
    }

    /// A remote window of the devbox agterm-server. Its Linux sessions are staged through this Mac's control
    /// API, which the server creates, and closed there again when the test ends.
    func testRemoteWindow() throws {
        let seeded = try activeSessionID()
        try nameSeededWorkspace(seeded, "agterm")
        try ctl("theme", "set", "Nord")
        let remote = try openDevbox()
        try ctl("window", "select", remote)
        try sizeWindow(heroSize)

        let workspace = try XCTUnwrap(remoteWorkspaces(remote).first?["id"] as? String, "devbox lists no workspace")
        let original = try XCTUnwrap(remoteWorkspaces(remote).first?["name"] as? String)
        try ctl("workspace", "rename", "devbox", "--target", workspace, "--window", remote)
        onDevbox { try self.ctl("workspace", "rename", original, "--target", workspace, "--window", $0) }
        // the catalog's own session loses its shell whenever the container restarts, and an ended row draws
        // the slashed cloud, so it gets a fresh login shell first
        let resident = try XCTUnwrap((remoteWorkspaces(remote).first?["sessions"] as? [[String: Any]])?.first)
        let residentID = try XCTUnwrap(resident["id"] as? String)
        if resident["ended"] as? Bool == true {
            try ctl("session", "restart", "--target", residentID, "--pane", "left", "--command", "/bin/zsh -l", "--window", remote)
        }
        let log = try remoteRow(remote, workspace, "agterm-server")
        try ctl("session", "split", "on", "--axis", "horizontal", "--target", log, "--window", remote)
        XCTAssertTrue(poll(until: self.paneText(log, pane: "left", window: remote) != nil
                           && self.paneText(log, pane: "right", window: remote) != nil, timeout: 30),
                      "both shells on devbox should start")
        try ctl("session", "type", "--target", log, "--pane", "left", "--window", remote,
                "clear; systemctl --user status agterm-server --no-pager -n 0\n")
        try ctl("session", "type", "--target", log, "--pane", "right", "--window", remote, "top\n")
        let release = try remoteRow(remote, workspace, "release", info: "🐧 **Ubuntu 24.04**")
        try ctl("session", "status", "completed", "--shape", "checkmark", "--target", release, "--window", remote)
        try ctl("session", "select", "--target", log, "--window", remote)
        try ctl("session", "context", "agterm-server on a Linux host", "--target", log, "--window", remote)

        XCTAssertTrue(poll(until: (self.paneText(log, pane: "right", window: remote) ?? "").contains("load average"),
                           timeout: 30), "top should draw in the lower pane")
        XCTAssertTrue(poll(until: (self.paneText(log, pane: "left", window: remote) ?? "").contains("active (running)"),
                           timeout: 30), "the agterm-server unit status should draw in the upper pane")
        XCTAssertTrue(poll(until: { let node = (try? self.remoteWorkspaces(remote))?
                .flatMap { $0["sessions"] as? [[String: Any]] ?? [] }.first { $0["id"] as? String == residentID }
            return node?["ended"] as? Bool != true
                && (node?["presentation"] as? [String: Any])?["state"] as? String == "connected" }(), timeout: 30),
                      "devbox's own session should be connected, not ended")
        try readyFrame()
        let shown = app.windows.matching(NSPredicate(format: "title == %@", "agterm-server — devbox")).firstMatch
        try capture("remote-window", size: heroSize, window: (shown, remote))
    }

    /// A devbox session attached into a local workspace beside local rows: the title bar names the host and the
    /// sidebar marks the row remote. The staging window is closed before the attach.
    func testRemoteAttach() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")

        let local = try activeWindowID()
        let staging = try openDevbox()
        let workspace = try XCTUnwrap(remoteWorkspaces(staging).first?["id"] as? String, "devbox lists no workspace")
        let origin = try remoteRow(staging, workspace, "devbox top", command: "top")
        XCTAssertTrue(poll(until: (try? self.runCLI(["zmx", "tree", self.devbox]).stdout.contains(origin)) == true,
                           timeout: 30), "devbox should list the new session as attachable")
        try ctl("window", "close", staging)

        try row("release notes", in: "agterm", info: "📦 **14** entries ^[drafted](color: \"green\")")
        let attached = try ctl("zmx", "attach", devbox, origin, "--window", local, "--workspace-name", "agterm")
        try row("server packaging", in: "agterm", info: "🌿 **linux-server** ^[● 2](color: \"orange\") ^[↑1](color: \"blue\")")
        try ctl("session", "select", "--target", attached)
        try ctl("session", "close", "--target", seeded)

        XCTAssertTrue(poll(until: (self.paneText(attached, pane: "left", window: nil) ?? "").contains("load average"),
                           timeout: 60), "top on devbox should draw in the attached row")
        try readyFrame()
        try capture("remote-attach", size: heroSize)
    }

    // MARK: - staging

    /// The agterm-server-test container, reached through the `devbox` ssh alias so rows read as a host name.
    private let devbox = "devbox"

    /// The session palette over a tig history view, listing sessions from three workspaces with their
    /// directories.
    func testSessionPalette() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")

        let history = try row("history", in: "agterm", command: "/bin/zsh -lc 'exec tig'", select: true)
        try ctl("session", "close", "--target", seeded)
        try row("html origin", in: "agterm", cwd: "\(repoRoot)/agtermCore/Sources/agtermCore")
        try row("page zoom", in: "agterm", cwd: "\(repoRoot)/agterm/Views")
        try row("markdown pages", in: "overlay docs", cwd: "\(repoRoot)/docs")
        try row("text pages", in: "overlay docs", cwd: "\(repoRoot)/docs")
        try row("docs preview", in: "site", cwd: "\(repoRoot)/site")
        try row("release notes", in: "root")

        XCTAssertTrue(poll(until: (self.paneText(history, pane: "left", window: nil) ?? "").contains("[main]"), timeout: 30),
                      "tig should draw its history")
        try readyFrame()
        let field = try openPalette("Go to Session")
        field.click()
        field.typeText("docs")
        XCTAssertTrue(poll(until: field.value as? String == "docs", timeout: 5), "the palette query should read docs")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try capture("session-palette", size: heroSize)
    }

    /// yazi on the site sources in a floating overlay, as the keymap's own Yazi command opens it.
    func testFloatingOverlay() throws {
        let seeded = try activeSessionID()
        try sizeWindow(wideSize)
        try ctl("theme", "set", "Catppuccin Mocha")
        try nameSeededWorkspace(seeded, "agterm")

        let notes = try row("landing page", in: "site", cwd: "\(repoRoot)/site",
                            command: "/bin/zsh -lc 'exec nvim \(nvimOnTheme) index.html'", select: true)
        try ctl("session", "close", "--target", seeded)
        try row("docs preview", in: "site", cwd: "\(repoRoot)/site")
        try row("core tests", in: "agterm", cwd: "\(repoRoot)/agtermCore")

        XCTAssertTrue(poll(until: (self.paneText(notes, pane: "left", window: nil) ?? "").contains("<html"), timeout: 30),
                      "nvim should draw the page under the overlay")
        // the keymap's Yazi line, run here directly: a custom command's bare agtermctl cannot reach the
        // harness socket
        // yazi's stderr carries a "purging events up to event id" line that lands over its header row
        let yaziLog = markerDir.appendingPathComponent("yazi.log").path
        try ctl("session", "overlay", "open", "zsh -lc 'yazi 2>\(yaziLog)'", "--size-percent", "95", "--target", notes)
        var listed = poll(until: self.overlayText(notes).contains("commands.html"), timeout: 30)
        // the user's yazi config shows hidden files, and the repo root holds local tool state; `.` hides them
        if listed {
            app.typeKey(".", modifierFlags: [])
            listed = poll(until: { let text = self.overlayText(notes)
                return text.contains("commands.html") && !text.contains(".ruff_cache") }(), timeout: 10)
        }
        try readyFrame()
        try capture(listed ? "floating-overlay" : "floating-overlay-diagnostic", size: wideSize)
        XCTAssertTrue(listed, "yazi should list the site sources: \(overlayDiagnosis(notes)) | stderr: \(String(describing: try? String(contentsOfFile: yaziLog, encoding: .utf8)))")
    }

    /// File > Edit Keymap: keymap.conf in the user's editor, a floating overlay over the session.
    func testKeymapEditor() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")
        try installKeymap()

        let shell = try row("keymap", in: "agterm", select: true)
        try ctl("session", "close", "--target", seeded)
        try row("core tests", in: "agterm", cwd: "\(repoRoot)/agtermCore")
        try row("docs preview", in: "site", cwd: "\(repoRoot)/site")

        XCTAssertTrue(poll(until: self.paneText(shell, pane: "left", window: nil) != nil, timeout: 30), "the shell should start")
        app.menuBarItems["File"].click()
        app.menuItems["Edit Keymap…"].click()
        XCTAssertTrue(poll(until: self.overlayText(shell).contains("custom_command_palette"), timeout: 30),
                      "Edit Keymap should open keymap.conf in the editor")
        try readyFrame()
        try capture("keymap-editor", size: heroSize)
    }

    /// The built-in attention list over a source view, naming the two sessions that need the user.
    func testAttentionList() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try ctl("theme", "set", "Gruvbox Dark")
        try nameSeededWorkspace(seeded, "agterm")

        let source = try row("html origin", in: "agterm",
                             command: "/bin/zsh -lc 'exec bat --paging=always agtermCore/Sources/agtermCore/HtmlOverlay.swift'",
                             select: true)
        try ctl("session", "close", "--target", seeded)
        let release = try row("release notes", in: "agterm")
        try ctl("session", "status", "blocked", "--target", release)
        let tests = try row("core tests", in: "agterm", cwd: "\(repoRoot)/agtermCore")
        try ctl("session", "status", "completed", "--shape", "checkmark", "--target", tests)
        try row("markdown pages", in: "overlay docs", cwd: "\(repoRoot)/docs")
        try row("docs preview", in: "site", cwd: "\(repoRoot)/site")

        XCTAssertTrue(poll(until: (self.paneText(source, pane: "left", window: nil) ?? "").contains("ReplicaContent"), timeout: 30),
                      "bat should draw the source")
        try readyFrame()
        try openPalette("Go to Attention…")
        try capture("attention-list", size: heroSize)
    }

    /// lazygit filling one pane, its diff view on the history of one agtermCore file.
    func testFullPaneTUI() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try ctl("theme", "set", "Everforest Dark Med")
        try sizeWindow(wideSize)
        try nameSeededWorkspace(seeded, "agterm")

        let file = "agtermCore/Sources/agtermCore/HtmlOverlay.swift"
        let tui = try row("html origin", in: "agterm", command: "/bin/zsh -lc 'exec lazygit -f \(file)'", select: true)
        try ctl("session", "close", "--target", seeded)
        try row("core tests", in: "agterm", cwd: "\(repoRoot)/agtermCore")
        try row("docs preview", in: "site", cwd: "\(repoRoot)/site")

        XCTAssertTrue(poll(until: (self.paneText(tui, pane: "left", window: nil) ?? "").contains("Filtering by"), timeout: 30),
                      "lazygit should draw the file's history")
        try ctl("session", "type", "--target", tui, "\r")
        XCTAssertTrue(poll(until: (self.paneText(tui, pane: "left", window: nil) ?? "").contains("@@"), timeout: 30),
                      "lazygit should show the commit's patch")
        try readyFrame()
        try capture("full-pane-tui", size: wideSize)
    }

    /// Release prep in one split: a text watermark behind the history pane, a custom color behind the
    /// changelog pane, and tinted rows beside it.
    func testBackgrounds() throws {
        let seeded = try activeSessionID()
        try sizeWindow(wideSize)
        try nameSeededWorkspace(seeded, "agterm")

        let history = "/bin/zsh -lc 'git --no-pager log --oneline --no-decorate -n 10 v0.44.1..HEAD || exit 1; exec zsh -l'"
        let release = try row("release 0.45", in: "agterm", command: history, select: true)
        try ctl("session", "close", "--target", seeded)
        try ctl("session", "split", "on", "--target", release)
        try ctl("session", "focus", "left", "--target", release)
        XCTAssertTrue(poll(until: self.paneText(release, pane: "right", window: nil) != nil, timeout: 30),
                      "the split shell should start")
        try ctl("session", "type", "--target", release, "--pane", "right", "clear; glow -s dark -w 72 CHANGELOG.md | head -n $((LINES - 2))\n")
        try ctl("session", "background", "text", "RELEASE 0.45", "--opacity", "0.2", "--pane", "left", "--target", release)
        try ctl("session", "background", "color", "#1f2a36", "--pane", "right", "--target", release)

        let notes = try row("changelog check", in: "agterm")
        try ctl("session", "tint", "green", "--target", notes)
        let server = try row("server packaging", in: "agterm")
        try ctl("session", "tint", "purple", "--on", "icon,name", "--target", server)
        try row("docs preview", in: "site", cwd: "\(repoRoot)/site")

        let commit = try NSRegularExpression(pattern: "^[0-9a-f]{7,} \\S", options: .anchorsMatchLines)
        XCTAssertTrue(poll(until: { let text = self.paneText(release, pane: "left", window: nil) ?? ""
            return commit.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }(), timeout: 30),
                      "the left pane should list the commits since v0.44.1")
        XCTAssertTrue(poll(until: (self.paneText(release, pane: "right", window: nil) ?? "").contains("0.44.1"), timeout: 30),
                      "glow should render the changelog")
        let panes = try XCTUnwrap(sessionNode(id: release)["paneBackgrounds"] as? [String: Any])
        let left = panes["left"] as? [String: Any], right = panes["right"] as? [String: Any]
        XCTAssertEqual(left?["kind"] as? String, "text", "left pane background: \(panes)")
        XCTAssertEqual(left?["text"] as? String, "RELEASE 0.45", "left pane background: \(panes)")
        XCTAssertEqual(right?["kind"] as? String, "color", "right pane background: \(panes)")
        XCTAssertEqual((right?["colorHex"] as? String)?.lowercased(), "#1f2a36", "right pane background: \(panes)")
        try readyFrame()
        try capture("backgrounds", size: wideSize)
    }

    /// A frameless HUD pinned to the session's top edge as an alert that stays until it is closed, over the
    /// test run it reports on.
    func testStatusBar() throws {
        let seeded = try activeSessionID()
        try sizeWindow(wideSize)
        try nameSeededWorkspace(seeded, "agterm")

        let tests = try row("core tests", in: "agterm", cwd: "\(repoRoot)/agtermCore",
                            command: "/usr/bin/tail -n 200 -f \(coreTestLog)", select: true)
        try ctl("session", "close", "--target", seeded)
        try ctl("session", "status", "completed", "--shape", "checkmark", "--target", tests)
        try row("release notes", in: "agterm")
        try row("server packaging", in: "agterm")
        try row("docs preview", in: "site", cwd: "\(repoRoot)/site")

        XCTAssertTrue(poll(until: (self.paneText(tests, pane: "left", window: nil) ?? "").contains("passed"), timeout: 30),
                      "the test log should draw")
        try ctl("session", "hud", "open", "--markdown", "--position", "top", "--sticky", "--no-frame", "--size-percent", "100",
                "--background-color", "#8a5a00", "--text-color", "#fff8e6", "--target", tests,
                "🔔 **v0.45.0 release** · ✅ **\(coreTestCount)** tests passed in total · next: `make dist VERSION=0.45.0`")
        XCTAssertNotNil((try sessionNode(id: tests))["hud"], "the status bar should be up")
        try readyFrame()
        try capture("status-bar", size: wideSize)
    }

    /// The dashboard grid over six live sessions: Claude Code, codex and agy each answering a read-only
    /// question about agterm, beside the core test log, the history and the machine's load.
    func testDashboard() throws {
        let seeded = try activeSessionID()
        try sizeWindow(wideSize)
        try nameSeededWorkspace(seeded, "agterm")

        let rules = """
         Answer in at most four short bullets, after a first line whose first word is Answer, followed by a \
        colon. This is read-only: no edits, no commits, no questions to me. Write file paths relative to the \
        repository root and include no links or commit hashes.
        """
        let claude = try row("dashboard grid", in: "agterm", command: agentCommand("claude", prompt:
            "In agterm, what happens to an open dashboard grid when one of its sessions closes?" + rules), select: true)
        try ctl("session", "close", "--target", seeded)
        let codex = try row("live restore", in: "agterm", command: agentCommand("codex --no-daemon", prompt:
            "In agterm, what does a Live sessions launch do when the zmx daemon behind a pane is gone?" + rules))
        let agy = try row("ask dialog", in: "agterm", command: agentCommand("agy -i", prompt:
            "In agterm, how does agtermctl ask decide between a native dialog and an ask drawn in the terminal?" + rules))
        let tests = try row("core tests", in: "agterm", cwd: "\(repoRoot)/agtermCore",
                            command: "/usr/bin/tail -n 80 -f \(coreTestLog)")
        let history = try row("history", in: "agterm", command: "/bin/zsh -lc 'exec tig'")
        let load = try row("load", in: "agterm", command: "/bin/zsh -lc 'exec htop -F agterm'")

        let agents = [claude, codex, agy]
        XCTAssertTrue(poll(until: agents.allSatisfy { self.answered($0) }, timeout: 900),
                      "every agent should finish its answer: \(agents.map { self.answered($0) })")
        try ctl("dashboard", claude, codex, agy, tests, history, load, "--auto-size")
        XCTAssertTrue(poll(until: { ((try? self.treeTop())?["dashboardMembers"] as? [String])?.count == 6 }(), timeout: 15),
                      "the dashboard should hold all six sessions")
        let cells = app.descendants(matching: .any).matching(identifier: "dashboard-cell")
        XCTAssertTrue(poll(until: cells.count == 6, timeout: 15), "the dashboard should draw six cells, drew \(cells.count)")
        try readyFrame()
        try capture("dashboard", size: wideSize)
    }

    /// An agent is done once it reports a completed turn and its pane opens a line with `Answer:`: the
    /// status alone passes a turn that ended without the answer, the text alone one still streaming its bullets.
    private func answered(_ session: String) -> Bool {
        guard let node = try? sessionNode(id: session), node["status"] as? String == "completed" else { return false }
        return paneOpensLine(session, "Answer:")
    }

    /// An agent waiting on the user: Claude Code reads how the dashboard caps its grid, marks its session
    /// blocked and asks through `agtermctl ask`, a terminal-style dialog drawn over its own session.
    func testAgentAsk() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try ctl("theme", "set", "Rose Pine Moon")
        try nameSeededWorkspace(seeded, "agterm")

        let prompt = """
        agterm's dashboard grid holds at most nine panes, and a split session takes two cells. Read how that cap \
        is enforced, then ask me how a tenth pane should be handled. Read-only: no edits, no commits.
        """
        // the command shape rides in the system prompt so the pane shows the question, not its scaffolding
        let shape = markerDir.appendingPathComponent("ask-shape.txt")
        try """
        When you ask the user, use exactly one Bash command of this shape, filling in the quoted texts and the \
        three choice ids, labels and subtitles from what you found, then wait for the answer:
        agtermctl session status blocked --target "$AGTERM_SESSION_ID" --socket "$AGTERM_SOCKET" && \
        agtermctl ask open "TITLE" --style terminal --target "$AGTERM_SESSION_ID" --socket "$AGTERM_SOCKET" \
        --message "ONE SENTENCE" --choice "a=LABEL" --choice-subtitle "a=TEXT" --choice "b=LABEL" \
        --choice-subtitle "b=TEXT" --choice "c=LABEL" --choice-subtitle "c=TEXT" --other "something else"
        """.write(to: shape, atomically: true, encoding: .utf8)
        let agent = try row("dashboard cap", in: "agterm", command: agentCommand("claude --append-system-prompt-file \(shape.path)",
                                                                                  prompt: prompt), select: true)
        try ctl("session", "close", "--target", seeded)
        let tests = try row("core tests", in: "agterm", cwd: "\(repoRoot)/agtermCore",
                            command: "/usr/bin/tail -n 200 -f \(coreTestLog)")
        try ctl("session", "status", "completed", "--target", tests)
        _ = try row("docs preview", in: "site",
                    command: "/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1 --directory site",
                    info: "🌐 ^[localhost:8765](color: \"blue\")")

        XCTAssertTrue(poll(until: { guard let node = try? self.sessionNode(id: agent) else { return false }
            return node["ask"] != nil && node["status"] as? String == "blocked" }(), timeout: 600),
                      "the agent should mark itself blocked and open its ask: \(String(describing: try? sessionNode(id: agent)))")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "ask-dialog").firstMatch.waitForExistence(timeout: 15),
                      "the ask should draw over the session")
        try readyFrame()
        try capture("agent-ask", size: heroSize)
    }

    /// A HUD with a spinner over a session whose test output is still scrolling: a replay of the passing
    /// agtermCore log, the panel naming the run.
    func testHUDSpinner() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")

        // per-test results only, so output scrolls at once and no runner summary ends the run on screen
        let replay = "zmodload zsh/zselect; grep \" passed after \" \(coreTestLog) | grep -v \"Test run with\" | " +
            "while IFS= read -r l; do print -r -- \"$l\"; zselect -t 1; done"
        let tests = try row("core tests", in: "agterm", cwd: "\(repoRoot)/agtermCore", command: "/bin/zsh -lc '\(replay)'",
                            info: "⏳ ^[swift test](color: \"yellow\") ^[agtermCore](dim: true)", select: true)
        try ctl("session", "close", "--target", seeded)
        _ = try row("release notes", in: "agterm", command: "/bin/zsh -lc 'exec zsh -l'")
        _ = try row("docs preview", in: "site",
                    command: "/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1 --directory site",
                    info: "🌐 ^[localhost:8765](color: \"blue\")")

        XCTAssertTrue(poll(until: (self.paneText(tests, pane: "left", window: nil) ?? "").contains(" passed after "), timeout: 30),
                      "the replay should be printing test results")
        try ctl("session", "hud", "open", "swift test · agtermCore", "--detail", "\(coreTestCount) tests across the runners",
                "--spinner-style", "braille", "--position", "top-right", "--target", tests)
        XCTAssertNotNil((try sessionNode(id: tests))["hud"], "the HUD should be up")
        try readyFrame()
        let shown = try XCTUnwrap(paneText(tests, pane: "left", window: nil), "the pane should read back")
        XCTAssertTrue(shown.contains(" passed after ") && !shown.contains("Test run with"),
                      "the replay should still be scrolling test results under the HUD")
        try capture("hud-spinner", size: heroSize)
    }

    /// The native picker over a release session: the repo's gates from its Makefile, each with the target's
    /// own description, the suite that already passed carrying its completed glyph.
    func testGatePicker() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")

        let release = try row("release 0.45", in: "agterm", command: "/bin/zsh -lc 'make help; exec zsh -l'", select: true)
        try ctl("session", "close", "--target", seeded)
        _ = try row("changelog check", in: "agterm", command: "/bin/zsh -lc 'exec zsh -l'")
        _ = try row("docs preview", in: "site",
                    command: "/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1 --directory site",
                    info: "🌐 ^[localhost:8765](color: \"blue\")")
        XCTAssertTrue(poll(until: (self.paneText(release, pane: "left", window: nil) ?? "").contains("test-app"), timeout: 30),
                      "make help should list the targets")

        let items: [[String: Any]] = [
            ["id": "test", "label": "make test", "subtitle": "host-free agtermCore unit tests · \(coreTestCount) passed",
             "status": "completed"],
            ["id": "test-app", "label": "make test-app", "subtitle": "application-hosted AppKit unit tests"],
            ["id": "lint", "label": "make lint", "subtitle": "swiftlint over the tree, warnings fail too"],
            ["id": "release", "label": "make release", "subtitle": "release build, no launch"],
            ["id": "dist", "label": "make dist VERSION=0.45.0", "subtitle": "signed and notarized DMG"],
        ]
        let request = try JSONSerialization.data(withJSONObject: ["cmd": "pick.open",
                                                                  "args": ["items": items, "prompt": "Choose a release step"]])
        let response = try sendCommand(String(decoding: request, as: UTF8.self))
        XCTAssertEqual(response["ok"] as? Bool, true, "pick.open should succeed: \(response)")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pick-palette").firstMatch.waitForExistence(timeout: 10),
                      "the picker should draw")
        try readyFrame()
        try capture("gate-picker", size: heroSize)
    }

    /// Notifications alone: idle rows whose programs posted `notify`, each carrying its unseen badge, and
    /// no agent status anywhere in the window.
    func testNotifications() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")

        let edit = try row("html origin", in: "agterm",
                           command: "/bin/zsh -lc 'exec nvim \(nvimOnTheme) +104 agtermCore/Sources/agtermCore/HtmlOverlay.swift'", select: true)
        try ctl("session", "close", "--target", seeded)
        let tests = try row("core tests", in: "agterm", cwd: "\(repoRoot)/agtermCore",
                            command: "/usr/bin/tail -n 200 -f \(coreTestLog)")
        let release = try row("release notes", in: "agterm", command: "/bin/zsh -lc 'exec zsh -l'")
        let preview = try row("docs preview", in: "site",
                              command: "/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1 --directory site",
                              info: "🌐 ^[localhost:8765](color: \"blue\")")
        XCTAssertTrue(poll(until: (self.paneText(edit, pane: "left", window: nil) ?? "").contains("struct HtmlOrigin"), timeout: 30),
                      "neovim should show the file")

        try ctl("notify", "\(coreTestCount) tests passed in 4 runners", "--title", "core tests", "--target", tests)
        try ctl("notify", "v0.44.1 section drafted: 2 improvements, 3 fixes", "--title", "release notes", "--target", release)
        try ctl("notify", "CHANGELOG.md links checked, none broken", "--title", "release notes", "--target", release)
        try ctl("notify", "docs.html served on localhost:8765", "--title", "docs preview", "--target", preview)
        let expected = [tests: 1, release: 2, preview: 1]
        XCTAssertTrue(poll(until: expected.allSatisfy { id, count in
            ((try? self.sessionNode(id: id))?["unseen"] as? Int) == count }, timeout: 15), "each row should carry its badge")
        for id in [edit, tests, release, preview] {
            XCTAssertNil((try sessionNode(id: id))["status"], "no row should carry an agent status")
        }
        try readyFrame(keepUnseen: true)
        try capture("notifications", size: heroSize)
    }

    /// Compact density on a full maintainer day: about thirty rows across five workspaces, companions and a
    /// folded parent, one agent working in the selected pane.
    func testCompactDensity() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "fixes")
        try ctl("sidebar", "density", "compact")

        // the agent starts last, so it is still at work once every other row is staged
        let agent = try row("pane leaders", in: "fixes", select: true)
        try ctl("session", "close", "--target", seeded)
        _ = try row("ZmxClient.swift", parent: agent,
                    command: "/bin/zsh -lc 'exec nvim \(nvimOnTheme) agterm/Ghostty/ZmxClient.swift'")
        let tests = try row("core tests", parent: agent, cwd: "\(repoRoot)/agtermCore",
                            command: "/usr/bin/tail -n 40 -f \(coreTestLog)")
        try ctl("session", "status", "completed", "--target", tests)
        let retry = try row("reconnect retry", in: "fixes")
        for name in ["reconnect panel", "lead cover"] { _ = try row(name, parent: retry) }
        try ctl("session", "collapse", "--target", retry)
        let leak = try row("disclosure leak", in: "fixes")
        try ctl("session", "status", "blocked", "--target", leak)
        _ = try row("background shells", in: "fixes")

        let review = try row("#1101 pane leaders", in: "reviews")
        _ = try row("diff", parent: review)
        for name in ["#1100 reconnect retry", "#1098 background shells", "#1097 disclosure leak", "#1095 lead cover click"] {
            _ = try row(name, in: "reviews")
        }

        let release = try row("release 0.45", in: "release")
        for name in ["changelog", "dist"] { _ = try row(name, parent: release) }
        _ = try row("server packaging", in: "release")
        for name in ["docs preview", "screenshots"] { _ = try row(name, in: "site") }
        for name in ["annotate-document", "attention"] { _ = try row(name, in: "cookbook") }

        XCTAssertTrue(poll(until: self.paneText(agent, pane: "left", window: nil) != nil, timeout: 30), "the shell should start")
        let launch = try agentCommand("claude", prompt: """
            Review agterm/Ghostty/ZmxClient.swift for defects in how it reads pane leaders and kills daemons. Read \
            every function and its callers before answering, then list at most five findings with line numbers. \
            Read-only: no edits, no commits, no questions to me. Write file paths relative to the repository root \
            and include no links or commit hashes.
            """)
        try ctl("session", "type", "--target", agent, "clear; exec \(launch)\n")
        XCTAssertTrue(poll(until: { guard let node = try? self.sessionNode(id: agent) else { return false }
            let text = self.paneText(agent, pane: "left", window: nil) ?? ""
            return node["status"] as? String == "active" && text.range(of: "Searched|Explored|Ran ", options: .regularExpression) != nil
        }(), timeout: 180),
                      "the agent should be at work in the selected pane")
        XCTAssertEqual((try treeTop())["sidebarDensity"] as? String, "compact")
        try readyFrame()
        XCTAssertEqual((try sessionNode(id: agent))["status"] as? String, "active", "the agent should still be working")
        try capture("compact-density", size: heroSize)
    }

    /// The sidebar as the subject: info lines in every markdown style the recipes draw, three statuses in
    /// different shapes, tints, a companion with its own status, a top-level session and a title-bar context.
    func testSidebarShowcase() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")

        let history = "/bin/zsh -lc 'git --no-pager log --graph --oneline -24 --decorate-refs=refs/heads/master || exit 1; exec zsh -l'"
        let polish = try row("sidebar polish", in: "agterm", command: history,
                             info: "🌿 **sidebar-reflow** ^[● 3](color: \"orange\") ^[↑2](color: \"blue\")", select: true)
        try ctl("session", "close", "--target", seeded)
        try ctl("session", "context", "rows grow a line when an info line is added", "--target", polish)
        try ctl("session", "status", "active", "--shape", "bolt", "--target", polish)
        let tests = try row("core tests", parent: polish, cwd: "\(repoRoot)/agtermCore",
                            command: "/usr/bin/tail -n 40 -f \(coreTestLog)",
                            info: "✅ **\(coreTestCount)** tests ^[passed](color: \"green\") ^[4 runners](dim: true)")
        try ctl("session", "status", "completed", "--shape", "star", "--target", tests)
        _ = try row("release notes", in: "agterm", info: "📦 **v0.44.1** ^[5 entries](color: \"green\") ^[drafted](dim: true)")
        let shots = try row("screenshots", in: "agterm", info: "📸 ^[9 staged](color: \"teal\") · ^[3 approved](color: \"green\")")
        try ctl("session", "tint", "teal", "--target", shots)
        let flakes = try row("ci flakes", in: "agterm", info: "⚠ ^[2 flaky on CI](color: \"yellow\") ^[docs/ci-flakes.md](dim: true)")
        try ctl("session", "status", "blocked", "--shape", "diamond", "--color", "#e0a030", "--target", flakes)
        _ = try row("docs", in: "site", info: "🌱 **hud-spinner** ^[● 1](color: \"orange\") ^[local only](dim: true)")
        _ = try row("docs preview", in: "site",
                    command: "/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1 --directory site",
                    info: "🌐 ^[localhost:8765](color: \"blue\")")
        try ctl("workspace", "tint", "purple", "--target", try workspaceID(named: "site"))
        // the sidebar is the subject here, so it gets the width its longest info lines need
        try ctl("sidebar", "width", "340")
        _ = try row("scratch notes", in: "root", info: "^[ideas for 0.46](dim: true)")

        XCTAssertTrue(poll(until: (self.paneText(polish, pane: "left", window: nil) ?? "").contains("*"), timeout: 30),
                      "the history graph should draw")
        try readyFrame()
        XCTAssertGreaterThanOrEqual((try treeTop())["sidebarWidth"] as? Double ?? 0, 340, "the sidebar should take the width")
        for (id, status) in [(polish, "active"), (tests, "completed"), (flakes, "blocked")] {
            XCTAssertEqual((try sessionNode(id: id))["status"] as? String, status, "staged status")
        }
        try capture("sidebar-showcase", size: heroSize)
    }

    /// A page as a session of its own: the command reference served from the repo's `site/` shown as a top-level
    /// page row at its overlay section, the dev server serving it as that row's companion, beside the session
    /// editing that section's source.
    func testPageSession() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try ctl("theme", "set", "GitHub Dark Dimmed")
        try nameSeededWorkspace(seeded, "site")

        let site = "\(repoRoot)/site"
        let edit = try row("overlay reference", in: "site", cwd: site,
                           command: "/bin/zsh -lc 'exec nvim \(nvimOnTheme) \"+/--url URL --page\" commands.html'", select: true)
        try ctl("session", "close", "--target", seeded)
        let server = try row("dev server", in: "site", cwd: site,
                             command: "/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1",
                             info: "🌐 ^[localhost:8765](color: \"blue\") ^[site/](dim: true)")
        _ = try row("docs screenshots", in: "site")
        XCTAssertTrue(poll(until: (self.paneText(server, pane: "left", window: nil) ?? "").contains("Serving HTTP"), timeout: 30),
                      "the dev server should listen")

        let opened = try runCLI(["session", "overlay", "open", "--url", "http://127.0.0.1:8765/commands.html#overlay", "--page",
                                 "--navigation",
                                 "--follow", "--target", edit, "--json"])
        XCTAssertEqual(opened.status, 0, "page open: \(opened.stderr)")
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(opened.stdout.utf8)) as? [String: Any])
        let page = try XCTUnwrap((reply["result"] as? [String: Any])?["id"] as? String, "the page row's id: \(reply)")
        try ctl("session", "rename", "command reference", "--target", page)
        try ctl("session", "move", "--parent", page, "--target", server)
        XCTAssertEqual((try sessionNode(id: server))["parent"] as? String, page, "the server should sit under its page")
        XCTAssertTrue(poll(until: self.pageShows(page, "An ephemeral terminal running one program"), timeout: 30),
                      "the command reference should render at its overlay section")
        // the section has no anchor at the --page entry, so the reference is scrolled to its card
        let web = app.webViews.firstMatch
        let card = web.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "URL --page [page flags]", "URL --page [page flags]"))
            .firstMatch
        // a web view's AX frame spans the whole document, so the window is what bounds the visible part;
        // the page's own header takes about its top 140 pt
        let top = app.windows.firstMatch.frame.minY
        let placed = { card.exists && card.frame.minY > top + 140 && card.frame.minY < top + 360 }
        var steps = 0
        while steps < 80, !placed() {
            web.scroll(byDeltaX: 0, deltaY: -200)
            steps += 1
        }
        XCTAssertTrue(card.exists, "the --page card should be on the page")
        XCTAssertTrue(placed(), "the --page card should sit near the top of the page")
        try readyFrame()
        try capture("page-session", size: heroSize)
    }

    /// agterm's own diff page over a real multi-file commit, at the link-open size with its file list open.
    func testDiffPage() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try ctl("theme", "set", "Everforest Dark Med")
        try nameSeededWorkspace(seeded, "agterm")

        let patch = markerDir.appendingPathComponent("pane-leaders.diff")
        let show = "git --no-pager show --no-color 2eedd326 -- agterm agtermCore agtermTests > \(patch.path) || exit 1; exec zsh -l"
        let fix = try row("pane leaders", in: "agterm", command: "/bin/zsh -lc '\(show)'",
                          info: "🌿 **zmx-leaders** ^[#1101](color: \"blue\")", select: true)
        try ctl("session", "close", "--target", seeded)
        try ctl("session", "context", "read pane leaders without zmx list", "--target", fix)
        try ctl("session", "status", "completed", "--target", fix)
        _ = try row("core tests", parent: fix, cwd: "\(repoRoot)/agtermCore", command: "/usr/bin/tail -n 40 -f \(coreTestLog)")
        _ = try row("release notes", in: "agterm")
        XCTAssertTrue(poll(until: ((try? Data(contentsOf: patch))?.count ?? 0) > 10_000 &&
                           (self.paneText(fix, pane: "left", window: nil) ?? "").contains("dev.umputun/agterm"), timeout: 30),
                      "the commit's patch should be written")

        try ctl("session", "overlay", "open", "--text", patch.path, "--size-percent", "95", "--target", fix)
        XCTAssertTrue(poll(until: self.pageShows(fix, "ControlServer+Respawn.swift"), timeout: 30), "the diff page should render")
        try ctl("session", "overlay", "files", "--go", "agterm/Ghostty/ZmxClient.swift", "--target", fix)
        XCTAssertTrue(poll(until: self.textPage(fix, pane: nil)?["files"].flatMap { ($0 as? [String: Any])?["path"] as? String }
                           == "agterm/Ghostty/ZmxClient.swift", timeout: 10), "the page should reach ZmxClient.swift")
        app.typeKey("f", modifierFlags: [])
        let filter = app.webViews.descendants(matching: .textField)
            .matching(NSPredicate(format: "placeholderValue == %@", "Filter files")).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "the file list should open")
        try readyFrame()
        try capture("diff-page", size: heroSize)
    }

    /// Two pages in one split session, each over its own pane: highlighted source at a marked line on the
    /// left, a test log that follows its growing end on the right.
    func testSourceAndLog() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try ctl("theme", "set", "Dracula")
        try nameSeededWorkspace(seeded, "agterm")

        let routing = try row("command routing", in: "agterm", select: true)
        try ctl("session", "close", "--target", seeded)
        try ctl("session", "context", "how session commands reach their handlers", "--target", routing)
        try ctl("session", "split", "on", "--target", routing)
        try ctl("session", "focus", "left", "--target", routing)
        _ = try row("release notes", in: "agterm", info: "📦 **v0.44.1** ^[5 entries](color: \"green\")")
        _ = try row("docs preview", in: "site",
                    command: "/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1 --directory site",
                    info: "🌐 ^[localhost:8765](color: \"blue\")")
        XCTAssertTrue(poll(until: self.paneText(routing, pane: "right", window: nil) != nil, timeout: 30),
                      "the split shell should start")

        let log = markerDir.appendingPathComponent("core-tests.log")
        try ctl("session", "type", "--target", routing, "--pane", "right",
                "clear; zmodload zsh/zselect; grep \" passed after \" \(coreTestLog) | grep -v \"Test run with\" | " +
                "while IFS= read -r l; do print -r -- \"$l\" >> \(log.path); zselect -t 5; done\n")
        XCTAssertTrue(poll(until: ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains(" passed after "), timeout: 30),
                      "the replay should start writing the log")

        let source = "\(repoRoot)/agtermCore/Sources/agtermCore/ControlDispatcher.swift"
        try ctl("session", "overlay", "open", "--text", source, "--line", "145", "--pane", "left", "--target", routing)
        try ctl("session", "overlay", "open", "--text", log.path, "--follow-file", "--pane", "right", "--target", routing)
        XCTAssertTrue(poll(until: self.textPage(routing, pane: "left")?["line"] as? Int == 145, timeout: 30),
                      "the left page should load the source at its marked line")
        XCTAssertTrue(poll(until: self.textPage(routing, pane: "right")?["following"] as? Bool == true, timeout: 30),
                      "the right page should load the log and follow it")
        XCTAssertTrue(poll(until: self.pageShows(routing, "dispatchSessionCommand") && self.pageShows(routing, " passed after "),
                           timeout: 30), "both pages should draw their text")
        XCTAssertEqual(Set((try sessionNode(id: routing))["paneOverlays"] as? [String] ?? []), ["left", "right"],
                       "each pane should carry its own page")
        try readyFrame()
        try capture("source-and-log", size: heroSize)
    }

    /// The first slide: a real Claude Code mid-answer on agterm, its session holding a companion of every kind
    /// (a log tail, a docs page, a Duplicate as Companion copy), beside a folded second parent.
    func testMainWindow() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try nameSeededWorkspace(seeded, "agterm")

        let api = try row("control api", in: "agterm", select: true)
        try ctl("session", "close", "--target", seeded)
        try ctl("session", "context", "how a page companion follows its parent", "--target", api)
        let tests = try row("core tests", parent: api, cwd: "\(repoRoot)/agtermCore",
                            command: "/usr/bin/tail -n 80 -f \(coreTestLog)",
                            info: "✅ **\(coreTestCount)** tests ^[passed](color: \"green\")")
        try ctl("session", "status", "completed", "--shape", "checkmark", "--target", tests)
        let runsTail = { (id: String) in
            ((try? self.sessionNode(id: id))?["foreground"] as? [String])?.first.map { ($0 as NSString).lastPathComponent } == "tail"
        }
        XCTAssertTrue(poll(until: runsTail(tests), timeout: 30), "core tests should run its tail before it is copied")
        let copied = try runCLI(["session", "duplicate", "--companion", "--no-select", "--target", tests])
        XCTAssertEqual(copied.status, 0, "duplicate as companion: \(copied.stderr)")
        let copy = copied.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(poll(until: runsTail(copy), timeout: 30), "the copy should run its own tail")
        XCTAssertEqual((try sessionNode(id: copy))["parent"] as? String, api, "the copy should sit under control api")
        try ctl("session", "rename", "core tests copy", "--target", copy)
        let release = try row("release notes", in: "agterm", info: "📦 **v0.44.1** ^[5 entries](color: \"green\")")
        _ = try row("changelog check", parent: release)
        _ = try row("dist", parent: release)
        try ctl("session", "collapse", "--target", release)
        let preview = try row("docs preview", in: "site", cwd: "\(repoRoot)/site",
                              command: "/usr/bin/python3 -m http.server 8765 --bind 127.0.0.1",
                              info: "🌐 ^[localhost:8765](color: \"blue\")")
        try ctl("workspace", "tint", "purple", "--target", try workspaceID(named: "site"))
        _ = try row("landing copy", in: "site", info: "🌿 **hero-refresh** ^[● 2](color: \"orange\")")
        _ = try row("scratch notes", in: "root", info: "^[ideas for 0.46](dim: true)")
        XCTAssertTrue(poll(until: (self.paneText(preview, pane: "left", window: nil) ?? "").contains("Serving HTTP"), timeout: 30),
                      "the docs server should listen")
        try ctl("session", "overlay", "open", "--url", "http://127.0.0.1:8765/docs.html#companions", "--companion",
                "--target", api)
        let page = try XCTUnwrap(poll(until: self.companionPage(of: api) != nil, timeout: 30) ? companionPage(of: api) : nil,
                                 "the page companion should join control api")
        try ctl("session", "rename", "companions guide", "--target", page)
        XCTAssertEqual(try companionIDs(of: api).count, 3, "control api should hold the log, its copy and the page")

        try ctl("session", "type", "--target", api, "clear; exec \(agentCommand("claude", prompt: """
            In agterm, how does a page companion stay attached to its parent session when the parent moves, closes \
            or is restored? Read the relevant code and its callers before answering, then answer in at most five \
            short bullets. Read-only: no edits, no commits, no questions to me. Write file paths relative to the \
            repository root and include no links or commit hashes.
            """))\n")
        XCTAssertTrue(poll(until: (try? self.sessionNode(id: api))?["status"] as? String == "active" &&
                           (self.paneText(api, pane: "left", window: nil) ?? "")
                               .range(of: "(Searched for|[Rr]ead|[Rr]an) [0-9]+ (pattern|file|shell)", options: .regularExpression) != nil,
                           timeout: 180),
                      "Claude Code should be working on the question")
        try ctl("session", "select", "--target", api)
        try readyFrame()
        XCTAssertEqual((try sessionNode(id: api))["status"] as? String, "active", "the agent should still be working")
        try capture("main", size: heroSize)
    }

    private func companionIDs(of parent: String) throws -> [String] {
        try treeWorkspaceNodes().flatMap { $0["sessions"] as? [[String: Any]] ?? [] }
            .filter { $0["parent"] as? String == parent }.compactMap { $0["id"] as? String }
    }

    private func companionPage(of parent: String) -> String? {
        let sessions = (try? treeWorkspaceNodes())?.flatMap { $0["sessions"] as? [[String: Any]] ?? [] } ?? []
        return sessions.first { $0["parent"] as? String == parent && $0["content"] != nil }?["id"] as? String
    }

    /// The command palette over a split session, narrowed to the split actions with their shortcuts.
    func testCommandPalette() throws {
        let seeded = try activeSessionID()
        try sizeWindow(heroSize)
        try ctl("theme", "set", "TokyoNight Storm")
        try nameSeededWorkspace(seeded, "agterm")

        let edit = try row("session moves", in: "agterm",
                           command: "/bin/zsh -lc 'exec nvim \(nvimOnTheme) +300 agtermCore/Sources/agtermCore/ControlDispatcher.swift'",
                           info: "🌿 **move-dispatch** ^[● 1](color: \"orange\")", select: true)
        try ctl("session", "close", "--target", seeded)
        try ctl("session", "context", "how a session move is dispatched", "--target", edit)
        try ctl("session", "split", "on", "--target", edit)
        try ctl("session", "focus", "left", "--target", edit)
        XCTAssertTrue(poll(until: self.paneText(edit, pane: "right", window: nil) != nil, timeout: 30), "the split shell should start")
        try ctl("session", "type", "--target", edit, "--pane", "right",
                "clear; git --no-pager log --oneline --no-decorate -12 -- agtermCore/Sources/agtermCore/ControlDispatcher.swift\n")
        _ = try row("core tests", parent: edit, cwd: "\(repoRoot)/agtermCore", command: "/usr/bin/tail -n 40 -f \(coreTestLog)")
        _ = try row("release notes", in: "agterm")
        _ = try row("docs preview", in: "site")
        XCTAssertTrue(poll(until: (self.paneText(edit, pane: "left", window: nil) ?? "").contains("dispatchSessionMove") &&
                           (self.paneText(edit, pane: "right", window: nil) ?? "").contains("control:"), timeout: 30),
                      "nvim and the history should draw")
        try readyFrame()
        let field = try openPalette("Command Palette")
        field.click()
        field.typeText("split")
        XCTAssertTrue(poll(until: field.value as? String == "split", timeout: 5), "the palette query should read split")
        XCTAssertTrue(app.staticTexts["Toggle Horizontal Split"].waitForExistence(timeout: 5), "the split actions should list")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try capture("command-palette", size: heroSize)
    }

    /// Claude Code and agy in a real /chat over a horizontal split, the agy pane on its own background color.
    func testPairClaudeAgy() throws {
        let seeded = try activeSessionID()
        try sizeWindow(wideSize)
        try ctl("theme", "set", "Catppuccin Mocha")
        try nameSeededWorkspace(seeded, "agterm")

        let pair = try row("agy hooks", in: "agterm", select: true)
        try ctl("session", "close", "--target", seeded)
        try ctl("session", "context", "which session an agy status hook reports to", "--target", pair)
        try ctl("session", "split", "on", "--axis", "horizontal", "--target", pair)
        try ctl("session", "focus", "left", "--target", pair)
        try ctl("session", "background", "color", "#1b1d2b", "--pane", "right", "--target", pair)
        XCTAssertTrue(poll(until: self.paneText(pair, pane: "right", window: nil) != nil, timeout: 30), "the split shell should start")
        let tests = try row("core tests", parent: pair, cwd: "\(repoRoot)/agtermCore", command: "/usr/bin/tail -n 80 -f \(coreTestLog)",
                            info: "✅ **\(coreTestCount)** ^[passed](color: \"green\")")
        try ctl("session", "status", "completed", "--shape", "checkmark", "--target", tests)
        _ = try row("release notes", in: "agterm", info: "📦 **v0.44.1** ^[5 entries](color: \"green\")")
        _ = try row("docs preview", in: "site", info: "🌐 ^[localhost:8765](color: \"blue\")")

        let topic = """
        /chat agy In agterm, the Antigravity CLI status hook (agterm/Resources/agent-status/agterm-agy-status.sh \
        with agent-owner.sh) has to report to the session agy runs in. How does it decide that session, and what \
        happens when agy was started outside agterm? This is read-only: no edits, no commits, no questions to me. \
        Settle it with agy, then finish with one short paragraph whose first word is Conclusion, followed by a colon; keep that word out of your messages to the peer. \
        Write file paths relative to the repository root and include no links or commit hashes.
        """
        try ctl("session", "type", "--target", pair, "--pane", "left", "clear; exec \(agentCommand("claude", prompt: topic))\n")
        XCTAssertTrue(poll(until: self.chatConcluded(pair), timeout: 900), "Claude should reach its verdict with agy")
        let peer = ((try sessionNode(id: pair))["splitForeground"] as? [String])?.first.map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(peer, "agy", "agy should be the peer in the right pane")
        try readyFrame()
        try capture("pair-agy", size: wideSize)
    }

    /// A keymap.conf as a user writes one: a few built-in rebinds and the custom commands the shots use.
    private func installKeymap() throws {
        let keymap = """
        # agterm keymap: `map` rebinds a built-in action, `command` adds your own.
        # A chord like ctrl+a>y is a prefix then a key; leave the chord out for a palette-only command.
        # {AGT_SESSION_ID} and $AGT_SESSION_PWD carry the session the command runs for.

        map ctrl+shift+r rename_session
        map ctrl+a>a toggle_split
        map ctrl+shift+o|ctrl+a>o custom_command_palette

        # tools in a floating panel over the session
        command "Yazi" ctrl+a>y agtermctl session overlay open 'zsh -lc yazi' --size-percent 90
        command "Lazygit" ctrl+a>l agtermctl session overlay open 'zsh -lc lazygit' --size-percent 95

        # sessions and pages next to the work
        command "Core Tests" ctrl+a>t --error-hud agtermctl session new --parent {AGT_SESSION_ID} --name "core tests" --cwd "$AGT_SESSION_PWD/agtermCore" --command "swift test"
        command "Docs Preview" ctrl+a>w agtermctl session overlay open --url http://127.0.0.1:8765/ --page
        command "Dashboard" agtermctl dashboard --mru --auto-size
        command "Open in Finder" ctrl+a>shift+o open "$AGT_SESSION_PWD"

        """
        // the sandboxed runner cannot write /tmp, so a shell of the app copies the file there
        let staged = markerDir.appendingPathComponent("keymap.conf")
        try keymap.write(to: staged, atomically: true, encoding: .utf8)
        let dir = try XCTUnwrap(shownConfigDir, "scripts/screenshots.sh passes the keymap directory")
        let copy = try row("copy keymap", command: "/bin/cp \(staged.path) \(dir)/keymap.conf")
        XCTAssertTrue(poll(until: (try? self.sessionNodeIfPresent(id: copy)) == nil, timeout: 15), "the keymap copy should finish")
        try ctl("keymap", "reload")
        let list = try JSONSerialization.jsonObject(with: Data(ctl("keymap", "list", "--json").utf8)) as? [String: Any]
        let loaded = (list?["result"] as? [String: Any])?["keymap"] as? [String: Any]
        XCTAssertEqual((loaded?["diagnostics"] as? [Any])?.count, 0, "the keymap should load cleanly: \(loaded ?? [:])")
        XCTAssertTrue(try ctl("keymap", "list").contains("Yazi"), "the keymap should load its Yazi command")
    }

    private func activeWindowID() throws -> String {
        let list = try JSONSerialization.jsonObject(with: Data(ctl("window", "list", "--json").utf8)) as? [String: Any]
        let windows = (list?["result"] as? [String: Any])?["windows"] as? [[String: Any]] ?? []
        return try XCTUnwrap(windows.first { $0["active"] as? Bool == true }?["id"] as? String, "no active window")
    }

    /// Runs `cleanup` at teardown with a devbox window opened again, or raised, for it; a refused step fails
    /// the test, since a leftover fixture shows in every later devbox shot.
    private func onDevbox(_ cleanup: @escaping @MainActor (String) throws -> Void) {
        addTeardownBlock { [self] in try cleanup(openDevbox()) }
    }

    /// Opens a remote window of devbox and waits for its catalog.
    private func openDevbox() throws -> String {
        let window = try ctl("window", "remote", "open", devbox)
        XCTAssertTrue(poll(until: !((try? self.remoteWorkspaces(window)) ?? []).isEmpty, timeout: 60),
                      "the devbox catalog should arrive")
        return window
    }

    private func remoteWorkspaces(_ window: String) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: Data(ctl("tree", "--json", "--window", window).utf8)) as? [String: Any]
        let tree = (json?["result"] as? [String: Any])?["tree"] as? [String: Any]
        return (tree?["workspaces"] as? [[String: Any]] ?? []).filter { $0["root"] as? Bool != true }
    }

    /// Creates a session on devbox through a remote window. It is closed there when the test ends, through a
    /// remote window opened again if this one is gone, so the shared catalog keeps only its own fixture.
    @discardableResult
    private func remoteRow(_ window: String, _ workspace: String, _ name: String, command: String? = nil,
                           info: String? = nil) throws -> String {
        var args = ["session", "new", "--window", window, "--workspace", workspace, "--name", name, "--no-select"]
        if let command { args += ["--command", command] }
        let result = try runCLI(args)
        XCTAssertEqual(result.status, 0, "agtermctl \(args.joined(separator: " ")): \(result.stderr)")
        // the server adds its operation receipt on a second line
        let id = String(result.stdout.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
        onDevbox { try self.ctl("session", "close", "--target", id, "--window", $0) }
        if let info { try ctl("session", "info", "--markdown", info, "--target", id, "--window", window) }
        return id
    }

    /// Opens a palette from the Navigate menu, as the palette tests do, and returns its search field.
    @discardableResult
    private func openPalette(_ menuTitle: String) throws -> XCUIElement {
        app.menuBars.menuBarItems["Navigate"].click()
        let item = app.menuItems[menuTitle]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Navigate should offer \(menuTitle)")
        item.click()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(menuTitle) should open its palette")
        return field
    }

    private func treeTop() throws -> [String: Any] {
        let result = try XCTUnwrap(sendCommand(#"{"cmd":"tree"}"#)["result"] as? [String: Any], "tree should carry a result")
        return try XCTUnwrap(result["tree"] as? [String: Any], "result should carry a tree")
    }

    /// What an overlay showed and how it ended, for a failure message: an exited program leaves no text.
    private func overlayDiagnosis(_ session: String) -> String {
        let text = try? runCLI(["session", "overlay", "text", "--target", session])
        let result = try? runCLI(["session", "overlay", "result", "--target", session])
        return "text \(text?.status ?? -1): \(text?.stdout ?? "") \(text?.stderr ?? "") | " +
            "result \(result?.status ?? -1): \(result?.stdout ?? "") \(result?.stderr ?? "")"
    }

    private func overlayText(_ session: String) -> String {
        (try? runCLI(["session", "overlay", "text", "--target", session]).stdout) ?? ""
    }

    private func paneText(_ session: String, pane: String, window: String?) -> String? {
        var args = ["session", "text", "--target", session, "--pane", pane]
        if let window { args += ["--window", window] }
        guard let result = try? runCLI(args), result.status == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    private func sizeWindow(_ size: (width: Int, height: Int)) throws {
        try ctl("window", "resize", "active", "--width", "\(size.width)", "--height", "\(size.height)")
        let list = try JSONSerialization.jsonObject(with: Data(ctl("window", "list", "--json").utf8)) as? [String: Any]
        let windows = (list?["result"] as? [String: Any])?["windows"] as? [[String: Any]] ?? []
        let geometry = windows.first { $0["active"] as? Bool == true }?["geometry"] as? [String: Any]
        XCTAssertEqual(geometry?["width"] as? Int, size.width, "window width was clamped: \(windows)")
        XCTAssertEqual(geometry?["height"] as? Int, size.height, "window height was clamped: \(windows)")
    }

    /// The seeded workspace takes the scene's name rather than staying beside it as "workspace 1".
    private func workspaceID(named name: String) throws -> String {
        let node = try XCTUnwrap(treeWorkspaceNodes().first { $0["name"] as? String == name }, "workspace \(name)")
        return try XCTUnwrap(node["id"] as? String, "workspace \(name) id")
    }

    private func nameSeededWorkspace(_ seeded: String, _ name: String) throws {
        let holder = try treeWorkspaceNodes().first { workspace in
            (workspace["sessions"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == seeded }
        }
        let workspace = try XCTUnwrap(holder?["id"] as? String, "no workspace holds the seeded session")
        try ctl("workspace", "rename", name, "--target", workspace)
    }

    /// Creates a session in the named workspace (`root` for a top-level one) or as a companion of `parent`.
    @discardableResult
    private func row(_ name: String, in workspace: String? = nil, parent: String? = nil, cwd: String? = nil,
                     command: String? = nil, info: String? = nil, select: Bool = false) throws -> String {
        var args = ["session", "new", "--name", name, "--cwd", cwd ?? repoRoot]
        if let parent { args += ["--parent", parent] }
        if workspace == "root" { args += ["--workspace", "root"] }
        if let workspace, workspace != "root" { args += ["--workspace-name", workspace, "--create-workspace"] }
        if let command { args += ["--command", command] }
        if !select { args.append("--no-select") }
        let result = try runCLI(args)
        XCTAssertEqual(result.status, 0, "agtermctl \(args.joined(separator: " ")): \(result.stderr)")
        let id = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let info { try ctl("session", "info", "--markdown", info, "--target", id) }
        return id
    }

    /// The prompt travels in a file because it passes through three quoting layers otherwise; a failed
    /// read ends the launch rather than starting the agent with an empty prompt.
    private func agentCommand(_ agent: String, prompt: String) throws -> String {
        let file = markerDir.appendingPathComponent("\(agent.split(separator: " ").first ?? "agent").prompt")
        try prompt.write(to: file, atomically: true, encoding: .utf8)
        return "/bin/zsh -lc 'p=$(cat \(file.path)) || exit 1; exec \(agent) \"$p\"'"
    }

    /// Ready once the agents worked and went quiet with a `← ` send line on screen in either pane and
    /// Claude's `Conclusion:` in the left one, after its last send line. The prompt never spells
    /// `Conclusion:` and Claude's footer carries its `←` mid-line, so neither matches before the exchange.
    private func chatConcluded(_ session: String) -> Bool {
        guard let node = try? sessionNode(id: session) else { return false }
        let status = node["status"] as? String
        if status == "active" || !(node["activePanes"] as? [String] ?? []).isEmpty {
            agentsWorked = true
            return false
        }
        guard agentsWorked, status != "blocked",
              let left = try? runCLI(["session", "text", "--target", session, "--pane", "left"]).stdout,
              let right = try? runCLI(["session", "text", "--target", session, "--pane", "right"]).stdout else { return false }
        // Conclusion: is Claude's own closing word, kept out of the exchange, and it follows every send line
        let lines = left.split(separator: "\n")
        guard let verdict = lines.lastIndex(where: { lineOpens($0, with: "Conclusion:") }) else { return false }
        let lastSend = lines.lastIndex { lineOpens($0, with: "→ ") || lineOpens($0, with: "← ") } ?? -1
        return verdict > lastSend && (opensLine(left, with: "← ") || opensLine(right, with: "← "))
    }

    private var agentsWorked = false

    private func turnEnded(_ session: String) -> Bool {
        guard let node = try? sessionNode(id: session) else { return false }
        let status = node["status"] as? String
        if status == "active" || !(node["activePanes"] as? [String] ?? []).isEmpty {
            agentsWorked = true
            return false
        }
        return agentsWorked && status != "blocked"
    }

    private func paneOpensLine(_ session: String, _ marker: String) -> Bool {
        guard let text = try? runCLI(["session", "text", "--target", session]).stdout else { return false }
        return opensLine(text, with: marker)
    }

    /// The review scripts' stderr, for a failure message: `markerDir` is gone after teardown.
    private var webrevLog: String {
        (try? String(contentsOf: markerDir.appendingPathComponent("webrev.log"), encoding: .utf8)) ?? "no webrev.log"
    }

    /// Dismisses a review page and waits for its script to exit, which closes the session: the script
    /// deletes its generated page only after it sees the dismissal, so a daemon reap must come later.
    private func closeReview(_ session: String) throws {
        try ctl("session", "overlay", "close", "--target", session)
        XCTAssertTrue(poll(until: (try? (self.sessionNodeIfPresent(id: session) == nil)) == true, timeout: 30),
                      "the review command should exit once its page is dismissed")
    }

    /// Keys go one at a time with no modifiers: `typeText` has delivered keys as Command chords.
    private func annotate(block: String, note: String) throws {
        let target = app.webViews.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", block, block)).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "the page should show \(block)")
        target.click()
        XCTAssertTrue(app.webViews.descendants(matching: .textView).firstMatch.waitForExistence(timeout: 5),
                      "a click on \(block) should open the note editor")
        for character in note { app.typeKey(String(character), modifierFlags: []) }
    }

    /// The `text` read-back of the loaded page over `pane` (nil for the session-wide slot).
    private func textPage(_ session: String, pane: String?) -> [String: Any]? {
        let pages = (try? sessionNodeIfPresent(id: session))?["htmlOverlays"] as? [[String: Any]] ?? []
        let page = pages.first { $0["pane"] as? String == pane && $0["state"] as? String == "loaded" }
        return page?["text"] as? [String: Any]
    }

    /// A page counts as shown once WebKit finished loading it and its script put `text` on screen:
    /// `loaded` alone passes a page whose script failed.
    private func pageShows(_ session: String, _ text: String) -> Bool {
        let pages = (try? sessionNodeIfPresent(id: session))?["htmlOverlays"] as? [[String: Any]] ?? []
        guard pages.contains(where: { $0["state"] as? String == "loaded" }) else { return false }
        let match = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        return app.webViews.descendants(matching: .any).matching(match).firstMatch.exists
    }

    /// Whether a line starts with `marker` once indentation and an agent's bullet glyph are skipped:
    /// Claude Code draws ⏺ or ●, codex •. Claude's own quote of a reply that arrived mid-turn has no
    /// text line, so codex's `← ` send line is the visible proof of the exchange.
    private func opensLine(_ text: String, with marker: String) -> Bool {
        text.split(separator: "\n").contains { lineOpens($0, with: marker) }
    }

    private func lineOpens(_ line: Substring, with marker: String) -> Bool {
        var body = line.drop { $0 == " " }
        if let first = body.first, "⏺●•".contains(first) { body = body.dropFirst().drop { $0 == " " } }
        return body.hasPrefix(marker)
    }

    // MARK: - capture

    /// Lets the frame settle, then marks every session seen: agents post notifications as they finish, and
    /// a badge beside a status breaks the site's staging rule. The notifications shot skips this.
    private func readyFrame(keepUnseen: Bool = false) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        for session in try treeWorkspaceNodes().flatMap({ $0["sessions"] as? [[String: Any]] ?? [] }) where !keepUnseen {
            guard let id = session["id"] as? String, session["unseen"] != nil else { continue }
            try ctl("session", "seen", "--target", id)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    /// Captures the frontmost window, or `window`'s element with its tree read from that window's id.
    private func capture(_ name: String, size: (width: Int, height: Int),
                         window: (element: XCUIElement, id: String)? = nil) throws {
        let shot = (window?.element ?? app.windows.firstMatch).screenshot()
        let rep = try XCTUnwrap(shot.image.representations.first)
        XCTAssertEqual(rep.pixelsWide, size.width * 2, "capture width")
        XCTAssertEqual(rep.pixelsHigh, size.height * 2, "capture height")
        try FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        try shot.pngRepresentation.write(to: shotsDir.appendingPathComponent("\(name).png"))
        let tree = try window.map { try ctl("tree", "--json", "--window", $0.id) } ?? ctl("tree", "--json")
        try Data(tree.utf8).write(to: shotsDir.appendingPathComponent("\(name).tree.json"))
    }

    // MARK: - helpers

    private var namespaceRecorded = false

    /// The session host outlives the app and has no idle exit, and the sandboxed runner cannot stop it, so
    /// the run's zmx namespace is recorded as soon as it is known for `scripts/screenshots.sh` to retire.
    private func recordNamespace() throws {
        guard !namespaceRecorded, let stateDir else { return }
        let line = Data((ZmxSupport.socketDirectory(forStateDirectory: stateDir.path) + "\n").utf8)
        let list = shotsDir.appendingPathComponent("zmx-namespaces")
        try FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: list.path) { try Data().write(to: list) }
        let handle = try FileHandle(forWritingTo: list)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        namespaceRecorded = true
    }

    private var shotsDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-shots", isDirectory: true)
    }

    /// The checkout this file is in; `repoRoot` maps a worktree to the main checkout the agents trust.
    private var checkoutRoot: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
    }

    private var repoRoot: String {
        guard let range = checkoutRoot.range(of: "/.claude/worktrees/") else { return checkoutRoot }
        return String(checkoutRoot[..<range.lowerBound])
    }

    /// A real `swift test` run of agtermCore that `scripts/screenshots.sh` saves, with its passed-test total.
    private var coreTestLog: String { "\(checkoutRoot)/build/screenshots-input/agtermcore-test.log" }

    private var coreTestCount: String {
        let total = Int(ProcessInfo.processInfo.environment["AGTERM_CORE_TESTS"] ?? "") ?? 0
        return total.formatted(.number.grouping(.automatic))
    }

    @discardableResult
    private func ctl(_ arguments: String...) throws -> String {
        let result = try runCLI(Array(arguments))
        XCTAssertEqual(result.status, 0, "agtermctl \(arguments.joined(separator: " ")): \(result.stderr)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
