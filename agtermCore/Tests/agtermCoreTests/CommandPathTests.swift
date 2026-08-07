import Foundation
import Testing
@testable import agtermCore

struct CommandPathTests {
    private let launchd = "/usr/bin:/bin:/usr/sbin:/sbin"

    @Test func widenedPutsBundledCLIFirstAndStandardDirsLast() {
        let path = CommandPath.widened(launchd, bundledCLIDirectory: "/App.app/Contents/MacOS")
        #expect(path == "/App.app/Contents/MacOS:\(launchd):/usr/local/bin:/opt/homebrew/bin")
    }

    @Test func widenedWithoutBundledCLIStillAppendsStandardDirs() {
        #expect(CommandPath.widened(launchd, bundledCLIDirectory: nil)
            == "\(launchd):/usr/local/bin:/opt/homebrew/bin")
    }

    @Test func widenedKeepsExistingEntryPositionInsteadOfDuplicating() {
        let path = CommandPath.widened("/opt/homebrew/bin:/usr/bin", bundledCLIDirectory: nil)
        #expect(path == "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
    }

    @Test func widenedDropsBundledCLIAlreadyOnPath() {
        let path = CommandPath.widened("/App.app/Contents/MacOS:/usr/bin",
                                       bundledCLIDirectory: "/App.app/Contents/MacOS")
        #expect(path == "/App.app/Contents/MacOS:/usr/bin:/usr/local/bin:/opt/homebrew/bin")
    }

    @Test func widenedFallsBackToLaunchdDefaultForMissingOrEmptyPath() {
        let expected = "\(launchd):/usr/local/bin:/opt/homebrew/bin"
        #expect(CommandPath.widened(nil, bundledCLIDirectory: nil) == expected)
        #expect(CommandPath.widened("", bundledCLIDirectory: nil) == expected)
    }

    @Test func widenedIgnoresEmptySegments() {
        #expect(CommandPath.widened("/usr/bin::/bin:", bundledCLIDirectory: "")
            == "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
    }
}
