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

    @Test func ghosttyConfigPathIsGhosttyConfInDir() {
        let dir = URL(fileURLWithPath: "/Users/test/.config/agterm")
        #expect(ConfigPaths.ghosttyConfigPath(configDirectory: dir).path == "/Users/test/.config/agterm/ghostty.conf")
    }

    @Test func editorCommandRunsThroughInteractiveLoginShellThenPosixSh() {
        // the login shell (-ilc) sources its rc + exports $EDITOR/$VISUAL, then execs /bin/sh which does the
        // POSIX ${VISUAL:-${EDITOR:-vi}} resolution — the POSIX text rides inside single quotes so a
        // non-POSIX login shell (fish) passes it through verbatim instead of choking on `${`.
        #expect(ConfigPaths.editorCommand(forPath: "/Users/test/.config/agterm/keymap.conf")
                == "${SHELL:-/bin/zsh} -ilc 'exec /bin/sh -c '\\''${VISUAL:-${EDITOR:-vi}} \"$1\"'\\'' agterm-config-edit '\\''/Users/test/.config/agterm/keymap.conf'\\'''")
    }

    @Test func editorCommandWorksForGhosttyConfigPath() {
        // the generalized command opens any path, including the ghostty.conf the new Edit action targets.
        let dir = URL(fileURLWithPath: "/Users/test/.config/agterm")
        let path = ConfigPaths.ghosttyConfigPath(configDirectory: dir).path
        #expect(ConfigPaths.editorCommand(forPath: path)
                == "${SHELL:-/bin/zsh} -ilc 'exec /bin/sh -c '\\''${VISUAL:-${EDITOR:-vi}} \"$1\"'\\'' agterm-config-edit '\\''/Users/test/.config/agterm/ghostty.conf'\\'''")
    }

    @Test func editorCommandResolvesExportedEditorAndPreservesPathAcrossShells() throws {
        // run the command exactly as libghostty does (/bin/sh -c "<cmd>") with a fake "editor" that records
        // its argument, isolating each candidate login shell from the machine's rc. Proves the nested
        // quoting survives, the exported $EDITOR resolves, and a path with a space AND an embedded single
        // quote reaches the editor intact. zsh always runs; fish runs only when installed — fish parses the
        // same because the POSIX logic runs under the inner /bin/sh (the old `$SHELL -ilc '${VISUAL:-…}'`
        // died under fish with `${ is not a valid variable`, exit 127).
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("agterm-editorcmd-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let got = tmp.appendingPathComponent("got")
        let editor = tmp.appendingPathComponent("fake-editor.sh")
        try "#!/bin/sh\nprintf '%s' \"$1\" > \"\(got.path)\"\n".write(to: editor, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editor.path)

        let path = tmp.appendingPathComponent("a b/o'd.conf").path // space + embedded single quote
        let cmd = ConfigPaths.editorCommand(forPath: path)

        var shells = ["/bin/zsh"]
        if let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first(where: { fm.isExecutableFile(atPath: $0) }) { shells.append(fish) }

        for shell in shells {
            try? fm.removeItem(at: got)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", cmd]
            var env = ProcessInfo.processInfo.environment
            env["SHELL"] = shell
            env["EDITOR"] = editor.path
            env["HOME"] = tmp.path            // isolate from the machine's rc (zsh/bash)
            env["ZDOTDIR"] = tmp.path         // zsh rc isolation
            env["XDG_CONFIG_HOME"] = tmp.path // fish config isolation
            env.removeValue(forKey: "VISUAL")
            proc.environment = env
            try proc.run()
            proc.waitUntilExit()
            #expect(proc.terminationStatus == 0, "command should exit 0 under \(shell)")
            #expect((try? String(contentsOf: got, encoding: .utf8)) == path,
                    "the path should reach the resolved editor intact under \(shell)")
        }
    }
}
