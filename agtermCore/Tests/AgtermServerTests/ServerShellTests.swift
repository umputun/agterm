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
                                                        program: .loginShell)

        #expect(launch.argv.isEmpty)
        #expect(launch.environment["ZDOTDIR"] == integration + "/zsh")
        #expect(launch.environment["GHOSTTY_ZSH_ZDOTDIR"] == "/home/u/.zsh")
        #expect(launch.environment["SHELL"] == "/bin/zsh")
    }

    @Test func fishFindsTheIntegrationAheadOfTheDataDirectories() {
        let launch = ServerShell.fish("/usr/bin/fish").launch(integration: integration, environment: [:], program: .loginShell)

        #expect(launch.argv.isEmpty)
        #expect(launch.environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] == integration)
        #expect(launch.environment["XDG_DATA_DIRS"] == integration + ":/usr/local/share:/usr/share")
    }

    @Test func bashStartsInPosixModeWithTheIntegrationAsItsEnv() {
        let launch = ServerShell.bash("/bin/bash").launch(integration: integration,
                                                          environment: ["HOME": "/home/u", "ENV": "/home/u/.env"], program: .loginShell)

        #expect(launch.argv == ["/bin/bash", "--posix", "-l"])
        #expect(launch.environment["ENV"] == integration + "/bash/ghostty.bash")
        #expect(launch.environment["GHOSTTY_BASH_ENV"] == "/home/u/.env")
        #expect(launch.environment["GHOSTTY_BASH_INJECT"] == "1")
        #expect(launch.environment["HISTFILE"] == "/home/u/.bash_history")
        #expect(launch.environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] == "1")
    }

    @Test func aCommandRunsOnceThroughTheLoginShell() {
        let program = ServerShell.Program.command("make test", wait: false)
        let zsh = ServerShell.zsh("/bin/zsh").launch(integration: integration, environment: [:], program: program)
        let fish = ServerShell.fish("/usr/bin/fish").launch(integration: integration, environment: [:], program: program)
        let bash = ServerShell.bash("/bin/bash").launch(integration: integration, environment: [:], program: program)

        #expect(zsh.argv == ["/bin/zsh", "-lic", ZmxReplayScript.renderEnding(commandLine: "make test")])
        #expect(fish.argv == ["/usr/bin/fish", "-lic", ZmxReplayScript.renderFishEnding(commandLine: "make test")])
        #expect(bash.argv == ["/bin/bash", "--posix", "-lic", ZmxReplayScript.renderEnding(commandLine: "make test")])
        #expect(bash.environment["ENV"] == integration + "/bash/ghostty.bash")
        #expect(bash.environment["GHOSTTY_BASH_INJECT"] == "1")
    }

    @Test func aWaitedCommandHoldsThePaneInEachShell() {
        let program = ServerShell.Program.command("make test", wait: true)
        let zsh = ServerShell.zsh("/bin/zsh").launch(integration: integration, environment: [:], program: program)
        let fish = ServerShell.fish("/usr/bin/fish").launch(integration: integration, environment: [:], program: program)
        let bash = ServerShell.bash("/bin/bash").launch(integration: integration, environment: [:], program: program)

        #expect(zsh.argv == ["/bin/zsh", "-lic", ZmxReplayScript.renderHolding(commandLine: "make test")])
        #expect(fish.argv == ["/usr/bin/fish", "-lic", ZmxReplayScript.renderFishHolding(commandLine: "make test", shell: "/usr/bin/fish")])
        #expect(bash.argv == ["/bin/bash", "--posix", "-lic", ZmxReplayScript.renderBashHolding(commandLine: "make test")])
    }

    @Test func aReturningCommandRunsThenTheIntegratedLoginShell() {
        let program = ServerShell.Program.returning("make test")
        let zsh = ServerShell.zsh("/bin/zsh").launch(integration: integration, environment: ["ZDOTDIR": "/home/u/.zsh"], program: program)
        let fish = ServerShell.fish("/usr/bin/fish").launch(integration: integration, environment: [:], program: program)
        let bash = ServerShell.bash("/bin/bash").launch(integration: integration, environment: ["HOME": "/home/u", "ENV": "/home/u/.env"],
                                                        program: program)

        #expect(zsh.argv == ["/bin/zsh", "-lic", ZmxReplayScript.render(commandLine: "make test", integrationDirectory: integration + "/zsh",
                                                                        inheritedZdotdir: "/home/u/.zsh", shell: "/bin/zsh")])
        #expect(fish.argv == ["/usr/bin/fish", "-lic", ZmxReplayScript.renderFish(commandLine: "make test", integrationRoot: integration,
                                                                                   shell: "/usr/bin/fish")])
        let exports = [("ENV", integration + "/bash/ghostty.bash"), ("GHOSTTY_BASH_INJECT", "1"), ("GHOSTTY_BASH_ENV", "/home/u/.env"),
                       ("HISTFILE", "/home/u/.bash_history"), ("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1")]
        #expect(bash.argv == ["/bin/bash", "--posix", "-lic", ZmxReplayScript.renderBash(commandLine: "make test", exports: exports,
                                                                                          shell: "/bin/bash")])
    }

    @Test func aReplayRunsTheProgramThenTheIntegratedLoginShell() {
        let argv = ["vim", "notes.md"]
        let zsh = ServerShell.zsh("/bin/zsh").launch(integration: integration, environment: ["ZDOTDIR": "/home/u/.zsh"],
                                                     program: .replay(argv))
        let fish = ServerShell.fish("/usr/bin/fish").launch(integration: integration, environment: [:], program: .replay(argv))
        let bash = ServerShell.bash("/bin/bash").launch(integration: integration, environment: ["HOME": "/home/u", "ENV": "/home/u/.env"],
                                                        program: .replay(argv))

        #expect(zsh.argv == ["/bin/zsh", "-lic", ZmxReplayScript.render(argv: argv, integrationDirectory: integration + "/zsh",
                                                                        inheritedZdotdir: "/home/u/.zsh", shell: "/bin/zsh")])
        #expect(fish.argv == ["/usr/bin/fish", "-lic", ZmxReplayScript.renderFish(argv: argv, integrationRoot: integration,
                                                                                   shell: "/usr/bin/fish")])
        let exports = [("ENV", integration + "/bash/ghostty.bash"), ("GHOSTTY_BASH_INJECT", "1"), ("GHOSTTY_BASH_ENV", "/home/u/.env"),
                       ("HISTFILE", "/home/u/.bash_history"), ("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1")]
        #expect(bash.argv == ["/bin/bash", "--posix", "-lic", ZmxReplayScript.renderBash(argv: argv, exports: exports, shell: "/bin/bash")])
    }
}
