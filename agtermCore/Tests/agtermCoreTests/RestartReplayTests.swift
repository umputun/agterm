import Testing
@testable import agtermCore

struct RestartReplayTests {
    @Test(arguments: [
        ["sleep", "600"],
        ["/bin/sh", "/usr/local/bin/cld", "--resume", "an id with spaces"],
        ["sh", "-c", "sleep 600; echo 'done'"],
        ["tool", ""],
    ])
    func aReadableProgramReplaysItsExactArgv(argv: [String]) {
        #expect(RestartReplay.resolve(foreground: .program(argv), denylist: ["tmux"]) == .success(argv))
    }

    @Test func aPaneWhoseForegroundCannotBeReadIsRefused() {
        #expect(RestartReplay.resolve(foreground: nil, denylist: []) == .failure(.unreadable))
    }

    @Test func aShellInTheForegroundIsRefused() {
        #expect(RestartReplay.resolve(foreground: .foregroundShell("zsh"), denylist: []) == .failure(.shell("zsh")))
    }

    @Test func aDenylistedProgramIsRefusedByItsBasename() {
        let result = RestartReplay.resolve(foreground: .program(["/opt/homebrew/bin/tmux", "attach"]), denylist: ["tmux"])

        #expect(result == .failure(.denylisted("tmux")))
    }

    @Test func anArgumentTheShellCannotReplayIsRefused() {
        #expect(RestartReplay.resolve(foreground: .program(["tool", "a\nb"]), denylist: []) == .failure(.unreplayable))
    }

    @Test func theRenderedLineIsHeldToTheExplicitCommandLimit() {
        let room = ControlSessionRestartOptions.maxCommandBytes - CommandRestore.shellQuotedLine(["tool", ""]).utf8.count
        let fits = ["tool", String(repeating: "a", count: room)]
        let over = ["tool", String(repeating: "a", count: room + 1)]

        #expect(RestartReplay.resolve(foreground: .program(fits), denylist: []) == .success(fits))
        #expect(RestartReplay.resolve(foreground: .program(over), denylist: []) == .failure(.tooLong))
    }

    @Test(arguments: [
        (RestartReplay.Refusal.unreadable, "the pane's foreground program cannot be read"),
        (.shell("zsh"), "no replayable foreground program: zsh holds the pane"),
        (.denylisted("tmux"), "tmux is on the restore denylist"),
        (.unreplayable, "the foreground program's arguments cannot be replayed"),
        (.tooLong, "the foreground program's command line is too long to replay (max 4096 bytes)"),
    ])
    func everyRefusalSaysNothingChangedAndNamesTheWayOut(refusal: RestartReplay.Refusal, reason: String) {
        #expect(refusal.message == reason + "; pass --command to name the line. nothing was changed")
    }
}
