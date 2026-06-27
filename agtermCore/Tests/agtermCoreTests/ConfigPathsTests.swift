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

    @Test func editorCommandRunsThroughInteractiveLoginShellWithViFallback() {
        // runs the editor via the user's interactive login shell so $EDITOR set in ~/.zshrc resolves;
        // the path is passed as the positional $1, single-quoted at the eval level.
        #expect(ConfigPaths.editorCommand(forPath: "/Users/test/.config/agterm/keymap.conf")
                == "${SHELL:-/bin/zsh} -ilc '${VISUAL:-${EDITOR:-vi}} \"$1\"' agterm-config-edit '/Users/test/.config/agterm/keymap.conf'")
    }

    @Test func editorCommandQuotesSpacesAndEmbeddedSingleQuotes() {
        // a path with a space stays one argument; an embedded single quote is escaped as '\'' so the
        // command can't break out of the quoting.
        #expect(ConfigPaths.editorCommand(forPath: "/a b/keymap.conf")
                == "${SHELL:-/bin/zsh} -ilc '${VISUAL:-${EDITOR:-vi}} \"$1\"' agterm-config-edit '/a b/keymap.conf'")
        #expect(ConfigPaths.editorCommand(forPath: "/o'd/keymap.conf")
                == "${SHELL:-/bin/zsh} -ilc '${VISUAL:-${EDITOR:-vi}} \"$1\"' agterm-config-edit '/o'\\''d/keymap.conf'")
    }

    @Test func editorCommandWorksForGhosttyConfigPath() {
        // the generalized command opens any path, including the ghostty.conf the new Edit action targets.
        let dir = URL(fileURLWithPath: "/Users/test/.config/agterm")
        let path = ConfigPaths.ghosttyConfigPath(configDirectory: dir).path
        #expect(ConfigPaths.editorCommand(forPath: path)
                == "${SHELL:-/bin/zsh} -ilc '${VISUAL:-${EDITOR:-vi}} \"$1\"' agterm-config-edit '/Users/test/.config/agterm/ghostty.conf'")
    }
}
