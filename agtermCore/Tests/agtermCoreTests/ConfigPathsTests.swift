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

    @Test func editorCommandRunsThroughInteractiveLoginShellWithViFallback() {
        // runs the editor via the user's interactive login shell so $EDITOR set in ~/.zshrc resolves;
        // the path is passed as the positional $1, single-quoted at the eval level.
        #expect(ConfigPaths.editorCommand(forKeymapPath: "/Users/test/.config/agterm/keymap.conf")
                == "${SHELL:-/bin/zsh} -ilc '${VISUAL:-${EDITOR:-vi}} \"$1\"' agterm-keymap-edit '/Users/test/.config/agterm/keymap.conf'")
    }

    @Test func editorCommandQuotesSpacesAndEmbeddedSingleQuotes() {
        // a path with a space stays one argument; an embedded single quote is escaped as '\'' so the
        // command can't break out of the quoting.
        #expect(ConfigPaths.editorCommand(forKeymapPath: "/a b/keymap.conf")
                == "${SHELL:-/bin/zsh} -ilc '${VISUAL:-${EDITOR:-vi}} \"$1\"' agterm-keymap-edit '/a b/keymap.conf'")
        #expect(ConfigPaths.editorCommand(forKeymapPath: "/o'd/keymap.conf")
                == "${SHELL:-/bin/zsh} -ilc '${VISUAL:-${EDITOR:-vi}} \"$1\"' agterm-keymap-edit '/o'\\''d/keymap.conf'")
    }
}
