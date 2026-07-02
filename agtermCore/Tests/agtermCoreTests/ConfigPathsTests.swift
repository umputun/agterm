import Foundation
import Testing
@testable import agtermCore

struct ConfigPathsTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    @Test func explicitSettingWins() {
        let dir = ConfigPaths.configDirectory(setting: "/custom/dir", stateDir: "/state", home: home)
        #expect(dir.path == "/custom/dir")
    }

    @Test func stateDirUsedWhenSetAndNoSetting() {
        let dir = ConfigPaths.configDirectory(setting: nil, stateDir: "/state", home: home)
        #expect(dir.path == "/state/config")
    }

    @Test func defaultWhenNeitherSettingNorStateDir() {
        let dir = ConfigPaths.configDirectory(setting: nil, stateDir: nil, home: home)
        #expect(dir.path == "/Users/test/.config/agterm")
    }

    @Test func emptyStringsFallThrough() {
        // an empty setting falls through to stateDir; an empty stateDir falls through to the default.
        #expect(ConfigPaths.configDirectory(setting: "", stateDir: "/state", home: home).path == "/state/config")
        #expect(ConfigPaths.configDirectory(setting: "", stateDir: "", home: home).path == "/Users/test/.config/agterm")
    }

    @Test func keymapPathIsKeymapConfInDir() {
        let dir = URL(fileURLWithPath: "/Users/test/.config/agterm")
        #expect(ConfigPaths.keymapPath(configDirectory: dir).path == "/Users/test/.config/agterm/keymap.conf")
    }

    @Test func starterKeymapConfIsCommentedAndListsActions() {
        let starter = ConfigPaths.starterKeymapConf()
        #expect(starter.contains("agterm keymap — a kitty-flavored config"))
        #expect(starter.contains("map <chord> <action>"))
        #expect(starter.contains("command \"<name>\" [chord] <shell...>"))
        #expect(starter.contains("single chord OR a leader like `ctrl+a>g`"))
        #expect(starter.contains("command \"Open in Zed\"  cmd+shift+e  open -a Zed \"$AGT_SESSION_PWD\""))
        #expect(starter.contains("command \"Lazygit\"      ctrl+a>g     agtermctl session overlay open lazygit --socket \"$AGT_SOCKET\""))
        #expect(starter.contains("command \"Deploy\"                    ./deploy.sh"))
        #expect(starter.contains("ctrl+shift+p"))
        #expect(!starter.contains("super"))
        for action in BuiltinAction.allCases {
            #expect(starter.contains("#   \(action.rawValue)"))
        }
        #expect(starter.contains("#   new_session"))
        #expect(starter.contains("cmd+n"))
        #expect(starter.contains("#   increase_font_size"))
        #expect(starter.contains("(not expressible)"))
        #expect(starter.contains("#   rename_session"))
        #expect(starter.contains("(no default)"))
        for token in CommandContext.tokenNames {
            #expect(starter.contains("#   {\(token)}"))
        }
        #expect(!starter.contains("{AGT_SESSION}"))
        #expect(!starter.contains("{AGT_WINDOW}"))
        #expect(!starter.contains("{AGT_CWD}"))
        #expect(starter.contains("a {AGT_X} token is substituted RAW into the /bin/sh line"))
        #expect(starter.contains("a remote host can also set"))
        #expect(starter.contains("the session title (OSC) and the working directory (OSC 7)"))
        #expect(starter.contains("{AGT_SESSION_NAME} and"))
        #expect(starter.contains("{AGT_SESSION_PWD} are equally unsafe raw"))
        #expect(starter.contains("environment variable, QUOTED, e.g. \"$AGT_SELECTION\""))
        let parsed = parseKeymap(starter)
        #expect(parsed.keymap.builtinOverrides.isEmpty)
        #expect(parsed.keymap.commands.isEmpty)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test func ghosttyConfigPathIsGhosttyConfInDir() {
        let dir = URL(fileURLWithPath: "/Users/test/.config/agterm")
        #expect(ConfigPaths.ghosttyConfigPath(configDirectory: dir).path == "/Users/test/.config/agterm/ghostty.conf")
    }

    @Test func restoreDenylistPathIsRestoreDenylistConfInDir() {
        let dir = URL(fileURLWithPath: "/Users/test/.config/agterm")
        #expect(ConfigPaths.restoreDenylistPath(configDirectory: dir).path == "/Users/test/.config/agterm/restore-denylist.conf")
    }

    @Test func editorCommandRunsThroughInteractiveLoginShellThenPosixSh() {
        // the login shell (-ilc) sources its rc + exports $EDITOR/$VISUAL, then execs /bin/sh which does the
        // POSIX ${VISUAL:-${EDITOR:-vi}} resolution — the POSIX text rides inside single quotes so a
        // non-POSIX login shell (fish) passes it through verbatim instead of choking on `${`.
        #expect(ConfigPaths.editorCommand(forPath: "/Users/test/.config/agterm/keymap.conf")
                == "${SHELL:-/bin/zsh} -ilc 'exec /bin/sh -c '\\''${VISUAL:-${EDITOR:-vi}} \"$1\"'\\'' agterm-config-edit '\\''/Users/test/.config/agterm/keymap.conf'\\'''")
    }

    @Test func editorCommandEmbedsAnyPathForBothEditorOverlays() {
        // both the keymap and ghostty-config Edit overlays call this one function; a different path is
        // embedded single-quoted with the same shape. Arbitrary-path integrity is proven behaviorally
        // below, so this only checks the call site, not the full golden string again.
        let dir = URL(fileURLWithPath: "/Users/test/.config/agterm")
        let cmd = ConfigPaths.editorCommand(forPath: ConfigPaths.ghosttyConfigPath(configDirectory: dir).path)
        #expect(cmd.hasPrefix("${SHELL:-/bin/zsh} -ilc 'exec /bin/sh -c "))
        #expect(cmd.contains("agterm-config-edit '\\''/Users/test/.config/agterm/ghostty.conf'\\'''"))
    }

    // MARK: - Cross-shell behavioral tests
    //
    // These run the command exactly as libghostty does (`/bin/sh -c "<cmd>"`) with a fake "editor" that
    // records its argument, isolating the login shell from the machine's rc via HOME/ZDOTDIR/XDG_CONFIG_HOME.
    // The `vi` fallback is intentionally not exercised behaviorally: it is the standard POSIX
    // `${VISUAL:-${EDITOR:-vi}}` default (pinned literally by the golden test above), and a behavioral check
    // would risk launching the real, tty-blocking `vi` — a login shell's /etc/{profile,zprofile} path_helper
    // reorders PATH so a system `/usr/bin/vi` would win over a fake one.

    /// Writes an executable recorder at `<dir>/<name>` that records its first argument to `<dir>/<name>.got`,
    /// returning the script path and the marker URL.
    private func makeRecorder(in dir: URL, named name: String) throws -> (script: String, got: URL) {
        let got = dir.appendingPathComponent("\(name).got")
        let script = dir.appendingPathComponent(name)
        try "#!/bin/sh\nprintf '%s' \"$1\" > \"\(got.path)\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, got)
    }

    private func makeTmp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-editorcmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Runs `editorCommand(forPath:)` under `/bin/sh -c` with `overrides` merged onto the process env;
    /// EDITOR/VISUAL are cleared first (so only `overrides` set them) and the login-shell rc is isolated to
    /// `tmp` via HOME/ZDOTDIR/XDG_CONFIG_HOME. Returns the exit status; a nil value in `overrides` removes a key.
    @discardableResult
    private func runEditorCommand(forPath path: String, tmp: URL, env overrides: [String: String?]) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", ConfigPaths.editorCommand(forPath: path)]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tmp.path
        env["ZDOTDIR"] = tmp.path
        env["XDG_CONFIG_HOME"] = tmp.path
        env.removeValue(forKey: "EDITOR")
        env.removeValue(forKey: "VISUAL")
        for (key, value) in overrides {
            if let value { env[key] = value } else { env.removeValue(forKey: key) }
        }
        proc.environment = env
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    @Test func editorCommandResolvesExportedEditorAndPreservesPath() throws {
        // an exported $EDITOR resolves and a path with a space AND an embedded single quote survives the
        // nested quoting, under zsh (a POSIX login shell, always present).
        let tmp = try makeTmp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (editor, got) = try makeRecorder(in: tmp, named: "editor")
        let path = tmp.appendingPathComponent("a b/o'd.conf").path
        let status = try runEditorCommand(forPath: path, tmp: tmp, env: ["SHELL": "/bin/zsh", "EDITOR": editor])
        #expect(status == 0)
        #expect((try? String(contentsOf: got, encoding: .utf8)) == path)
    }

    @Test func editorCommandPrefersVisualOverEditor() throws {
        // $VISUAL wins over $EDITOR (the ${VISUAL:-${EDITOR:-vi}} precedence), under zsh.
        let tmp = try makeTmp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (visual, visualGot) = try makeRecorder(in: tmp, named: "visual")
        let (editor, editorGot) = try makeRecorder(in: tmp, named: "editor")
        let path = tmp.appendingPathComponent("k.conf").path
        let status = try runEditorCommand(forPath: path, tmp: tmp,
                                          env: ["SHELL": "/bin/zsh", "VISUAL": visual, "EDITOR": editor])
        #expect(status == 0)
        #expect((try? String(contentsOf: visualGot, encoding: .utf8)) == path)
        #expect(!FileManager.default.fileExists(atPath: editorGot.path), "EDITOR must not run when VISUAL is set")
    }

    @Test func editorCommandSourcesLoginShellRcForExportedEditor() throws {
        // the `-ilc` hop is load-bearing: an $EDITOR exported only in the shell rc (NOT in the process env)
        // still resolves, because the login shell sources its rc before exec'ing /bin/sh. Without `-ilc` the
        // rc isn't sourced and this would fall back to vi.
        let tmp = try makeTmp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (editor, got) = try makeRecorder(in: tmp, named: "rc-editor")
        // zsh -i sources $ZDOTDIR/.zshrc; export EDITOR there and pass no EDITOR in the env.
        try "export EDITOR='\(editor)'\n".write(to: tmp.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let path = tmp.appendingPathComponent("k.conf").path
        let status = try runEditorCommand(forPath: path, tmp: tmp, env: ["SHELL": "/bin/zsh"])
        #expect(status == 0)
        #expect((try? String(contentsOf: got, encoding: .utf8)) == path)
    }

    @Test(.enabled(if: ConfigPathsTests.fishPath() != nil,
                   "no non-POSIX login shell (fish) installed — the cross-shell parse assertion is skipped here"))
    func editorCommandWorksUnderNonPosixLoginShell() throws {
        // the actual bug fix: a non-POSIX login shell (fish) must run the command without choking on `${`.
        // SKIPPED (visibly) when no fish is installed, so a green run on a POSIX-only box is not mistaken for
        // cross-shell verification.
        let fish = try #require(ConfigPathsTests.fishPath())
        let tmp = try makeTmp(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (editor, got) = try makeRecorder(in: tmp, named: "editor")
        let path = tmp.appendingPathComponent("a b/o'd.conf").path
        let status = try runEditorCommand(forPath: path, tmp: tmp, env: ["SHELL": fish, "EDITOR": editor])
        #expect(status == 0)
        #expect((try? String(contentsOf: got, encoding: .utf8)) == path)
    }

    /// The first installed `fish` binary, or nil — gates the non-POSIX behavioral test above.
    private static func fishPath() -> String? {
        ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
