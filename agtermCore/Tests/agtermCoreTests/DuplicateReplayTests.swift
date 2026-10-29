import Testing
@testable import agtermCore

struct DuplicateReplayTests {
    private func plan(_ foreground: CommandRestore.PaneForeground?, leader: Bool = false, cwd: String? = "/work",
                      executable: String? = "/opt/homebrew/bin/htop",
                      denylist: Set<String> = []) -> Result<DuplicateReplay.Plan, DuplicateReplay.Refusal> {
        let observation = RestartReplay.Observation(foreground: foreground, isDaemonLeader: leader, workingDirectory: cwd,
                                                    executablePath: executable)
        return DuplicateReplay.resolve(observation, pane: "left", fallbackDirectory: "/fallback", shell: "zsh", denylist: denylist)
    }

    private func refusal(_ reason: DuplicateReplay.Refusal.Reason) -> Result<DuplicateReplay.Plan, DuplicateReplay.Refusal> {
        .failure(DuplicateReplay.Refusal(pane: "left", reason: reason))
    }

    @Test func anIdleShellGivesAPlainShellWhereItSits() {
        #expect(plan(.foregroundShell("zsh")) == .success(.shell(workingDirectory: "/work")))
        #expect(plan(.foregroundShell("zsh"), cwd: nil) == .success(.shell(workingDirectory: "/fallback")))
    }

    @Test func aRunningProgramStartsAgainFromItsExecutableInItsDirectory() {
        #expect(plan(.program(["htop", "-d", "5"])) == .success(.program(argv: ["/opt/homebrew/bin/htop", "-d", "5"], workingDirectory: "/work")))
        #expect(plan(.program(["/usr/bin/top", "-o", "cpu"]), executable: nil)
            == .success(.program(argv: ["/usr/bin/top", "-o", "cpu"], workingDirectory: "/work")))
    }

    @Test func aBareProgramWithoutAnExecutablePathIsRefused() {
        #expect(plan(.program(["htop"]), executable: nil) == refusal(.noExecutable))
    }

    @Test func aDaemonLeaderShellRunningSomethingIsRefused() {
        #expect(plan(.program(["/bin/zsh", "script.sh"]), leader: true) == refusal(.replay(.shell("zsh"))))
    }

    @Test(arguments: [["grep", "a\\.b"], ["printf", "x\\"]])
    func anArgumentWithABackslashIsRefused(argv: [String]) {
        #expect(plan(.program(argv)) == refusal(.backslash))
    }

    @Test func theResolvedExecutableIsWhatTheChecksSee() {
        #expect(plan(.program(["htop"]), executable: "/odd\\dir/htop") == refusal(.backslash))
        #expect(plan(.program(["vi"]), executable: "/usr/bin/vim", denylist: ["vim"]) == refusal(.replay(.denylisted("vim"))))
    }

    @Test(arguments: [
        (CommandRestore.PaneForeground.program(["/usr/bin/vim"]), Set(["vim"]), RestartReplay.Refusal.denylisted("vim")),
        (nil, Set<String>(), RestartReplay.Refusal.unreadable),
    ])
    func aRefusedPaneIsNamedAndNothingIsCreated(foreground: CommandRestore.PaneForeground?, denylist: Set<String>,
                                                reason: RestartReplay.Refusal) {
        let expected = DuplicateReplay.Refusal(pane: "left", reason: .replay(reason))
        #expect(plan(foreground, denylist: denylist) == .failure(expected))
        #expect(expected.message == "left pane: \(reason.reason); nothing was created")
        #expect(!expected.message.contains("--command"))
    }

    @Test func aProgramWithoutADirectoryIsRefused() {
        #expect(plan(.program(["make"]), cwd: nil) == refusal(.replay(.noDirectory)))
    }
}
