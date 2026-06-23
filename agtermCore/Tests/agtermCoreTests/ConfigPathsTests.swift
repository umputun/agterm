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
}
