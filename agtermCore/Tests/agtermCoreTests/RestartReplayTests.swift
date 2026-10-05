import Testing
@testable import agtermCore

struct RestartReplayTests {
    private func resolve(_ foreground: CommandRestore.PaneForeground?, leader: Bool = false, directory: String? = "/work",
                         shell: String? = nil, denylist: Set<String> = []) -> Result<RestartReplay.Launch, RestartReplay.Refusal> {
        RestartReplay.resolve(.init(foreground: foreground, isDaemonLeader: leader, workingDirectory: directory),
                              shell: shell, denylist: denylist)
    }

    @Test(arguments: [
        ["sleep", "600"],
        ["/bin/sh", "/usr/local/bin/cld", "--resume", "an id with spaces"],
        ["sh", "-c", "sleep 600; echo 'done'"],
        ["zsh", "-lic", "echo hi"],
        ["tool", ""],
    ])
    func aReadableProgramReplaysItsExactArgvInItsOwnDirectory(argv: [String]) {
        #expect(resolve(.program(argv), denylist: ["tmux"]) == .success(.init(argv: argv, workingDirectory: "/work")))
    }

    @Test func aProgramThatReplacedTheRootShellIsStillReplayed() {
        #expect(resolve(.program(["sleep", "600"]), leader: true)
            == .success(.init(argv: ["sleep", "600"], workingDirectory: "/work")))
    }

    @Test(arguments: [
        (["/bin/zsh", "-lic", "'builtin' 'eval' -- 'read x' ; 'builtin' 'exec' -- '/bin/zsh' -il"], nil as String?, "zsh"),
        (["/bin/sh", "-c", "read x"], nil, "sh"),
        (["/opt/bin/xonsh", "-c", "input()"], "xonsh", "xonsh"),
    ])
    func theRootShellRunningItsOwnLineIsRefused(argv: [String], shell: String?, name: String) {
        #expect(resolve(.program(argv), leader: true, shell: shell) == .failure(.shell(name)))
    }

    @Test func aPaneWhoseForegroundCannotBeReadIsRefused() {
        #expect(resolve(nil) == .failure(.unreadable))
    }

    @Test func aShellInTheForegroundIsRefused() {
        #expect(resolve(.foregroundShell("zsh")) == .failure(.shell("zsh")))
    }

    @Test func aDenylistedProgramIsRefusedByItsBasename() {
        #expect(resolve(.program(["/opt/homebrew/bin/tmux", "attach"]), denylist: ["tmux"]) == .failure(.denylisted("tmux")))
    }

    @Test func anArgumentTheShellCannotReplayIsRefused() {
        #expect(resolve(.program(["tool", "a\nb"])) == .failure(.unreplayable))
    }

    @Test func theRenderedLineIsHeldToTheExplicitCommandLimit() {
        let room = ControlSessionRestartOptions.maxCommandBytes - CommandRestore.shellQuotedLine(["tool", ""]).utf8.count
        let fits = ["tool", String(repeating: "a", count: room)]
        let over = ["tool", String(repeating: "a", count: room + 1)]

        #expect(resolve(.program(fits)) == .success(.init(argv: fits, workingDirectory: "/work")))
        #expect(resolve(.program(over)) == .failure(.tooLong))
    }

    @Test func aProgramWhoseDirectoryIsUnavailableIsRefused() {
        #expect(resolve(.program(["sleep", "600"]), directory: nil) == .failure(.noDirectory))
    }

    @Test(arguments: [
        (RestartReplay.Refusal.unreadable, "the pane's foreground program cannot be read"),
        (.shell("zsh"), "no replayable foreground program: zsh holds the pane"),
        (.denylisted("tmux"), "tmux is on the restore denylist"),
        (.unreplayable, "the foreground program's arguments cannot be replayed"),
        (.tooLong, "the foreground program's command line is too long to replay (max 4096 bytes)"),
        (.noDirectory, "the foreground program's working directory is unavailable"),
    ])
    func everyRefusalSaysNothingChangedAndNamesTheWayOut(refusal: RestartReplay.Refusal, reason: String) {
        #expect(refusal.message == reason + "; pass --command to name the line. nothing was changed")
    }
}
