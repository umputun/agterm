import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

struct ServerShellTests {
    private let integration = "/srv/agterm/resources/shell-integration"

    @Test(arguments: ["/bin/zsh", "/usr/bin/fish", "/bin/bash"])
    func zshFishAndBashAreRun(path: String) {
        #expect(ServerShell.named(path)?.path == path)
    }

    @Test(arguments: ["/bin/tcsh", "/bin/sh", "/usr/bin/nu"])
    func anyOtherShellIsNot(path: String) {
        #expect(ServerShell.named(path) == nil)
    }

    @Test func zshLoadsTheIntegrationAndKeepsTheUsersDirectory() {
        let launch = ServerShell.zsh("/bin/zsh").launch(integration: integration, environment: ["ZDOTDIR": "/home/u/.zsh"],
                                                        command: nil)

        #expect(launch.argv.isEmpty)
        #expect(launch.environment["ZDOTDIR"] == integration + "/zsh")
        #expect(launch.environment["GHOSTTY_ZSH_ZDOTDIR"] == "/home/u/.zsh")
        #expect(launch.environment["SHELL"] == "/bin/zsh")
    }

    @Test func fishFindsTheIntegrationAheadOfTheDataDirectories() {
        let launch = ServerShell.fish("/usr/bin/fish").launch(integration: integration, environment: [:], command: nil)

        #expect(launch.argv.isEmpty)
        #expect(launch.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] == integration)
        #expect(launch.environment["XDG_DATA_DIRS"] == integration + ":/usr/local/share:/usr/share")
    }

    @Test func bashStartsInPosixModeWithTheIntegrationAsItsEnv() {
        let launch = ServerShell.bash("/bin/bash").launch(integration: integration,
                                                          environment: ["HOME": "/home/u", "ENV": "/home/u/.env"], command: nil)

        #expect(launch.argv == ["/bin/bash", "--posix", "-l"])
        #expect(launch.environment["ENV"] == integration + "/bash/ghostty.bash")
        #expect(launch.environment["GHOSTTY_BASH_ENV"] == "/home/u/.env")
        #expect(launch.environment["GHOSTTY_BASH_INJECT"] == "1")
        #expect(launch.environment["HISTFILE"] == "/home/u/.bash_history")
        #expect(launch.environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] == "1")
    }

    @Test func aCommandRunsOnceThroughTheLoginShell() {
        let zsh = ServerShell.zsh("/bin/zsh").launch(integration: integration, environment: [:], command: "make test")
        let fish = ServerShell.fish("/usr/bin/fish").launch(integration: integration, environment: [:], command: "make test")
        let bash = ServerShell.bash("/bin/bash").launch(integration: integration, environment: [:], command: "make test")

        #expect(zsh.argv == ["/bin/zsh", "-lic", ZmxReplayScript.renderEnding(commandLine: "make test")])
        #expect(fish.argv == ["/usr/bin/fish", "-lic", ZmxReplayScript.renderFishEnding(commandLine: "make test")])
        #expect(bash.argv == ["/bin/bash", "--posix", "-lic", ZmxReplayScript.renderEnding(commandLine: "make test")])
        #expect(bash.environment["ENV"] == integration + "/bash/ghostty.bash")
        #expect(bash.environment["GHOSTTY_BASH_INJECT"] == "1")
    }
}
