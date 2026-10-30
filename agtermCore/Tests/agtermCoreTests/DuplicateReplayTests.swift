import Testing
@testable import agtermCore

struct DuplicateReplayTests {
    private static let htop = "/opt/homebrew/bin/htop"

    private func plan(_ foreground: CommandRestore.PaneForeground?, leader: Bool = false, cwd: String? = "/work",
                      executable: String? = htop, searchPath: String? = "/opt/homebrew/bin",
                      files: [String: String] = [htop: htop],
                      denylist: Set<String> = []) -> Result<DuplicateReplay.Plan, DuplicateReplay.Refusal> {
        let observation = RestartReplay.Observation(foreground: foreground, isDaemonLeader: leader, workingDirectory: cwd,
                                                    executablePath: executable, searchPath: searchPath)
        return DuplicateReplay.resolve(observation, pane: "left", fallbackDirectory: "/fallback", shell: "zsh", denylist: denylist,
                                       resolvedFile: { files[$0] })
    }

    private func refusal(_ reason: DuplicateReplay.Refusal.Reason) -> Result<DuplicateReplay.Plan, DuplicateReplay.Refusal> {
        .failure(DuplicateReplay.Refusal(pane: "left", reason: reason))
    }

    @Test func anIdleShellGivesAPlainShellWhereItSits() {
        #expect(plan(.foregroundShell("zsh")) == .success(.shell(workingDirectory: "/work")))
        #expect(plan(.foregroundShell("zsh"), cwd: nil) == .success(.shell(workingDirectory: "/fallback")))
    }

    @Test func aRunningProgramStartsAgainFromWhereItWasFoundInItsDirectory() {
        #expect(plan(.program(["htop", "-d", "5"])) == .success(.program(argv: [Self.htop, "-d", "5"], workingDirectory: "/work")))
        #expect(plan(.program(["/usr/bin/top", "-o", "cpu"]), executable: nil, searchPath: nil)
            == .success(.program(argv: ["/usr/bin/top", "-o", "cpu"], workingDirectory: "/work")))
    }

    // the resolved image lost the invoked name, so vimdiff ran as plain vim and a venv python as the base interpreter
    @Test func aSymlinkedNameIsCopiedByThePathItWasStartedFrom() {
        let vimdiff = plan(.program(["vimdiff", "a", "b"]), executable: "/usr/bin/vim", searchPath: "/opt/homebrew/bin:/usr/bin",
                           files: ["/usr/bin/vimdiff": "/usr/bin/vim", "/usr/bin/vim": "/usr/bin/vim"])
        #expect(vimdiff == .success(.program(argv: ["/usr/bin/vimdiff", "a", "b"], workingDirectory: "/work")))
        let python = "/usr/local/bin/python3.12"
        let venv = plan(.program(["python", "app.py"]), executable: python, searchPath: "/work/.venv/bin:/usr/local/bin",
                        files: ["/work/.venv/bin/python": python, "/usr/local/bin/python": python, python: python])
        #expect(venv == .success(.program(argv: ["/work/.venv/bin/python", "app.py"], workingDirectory: "/work")))
    }

    @Test func aPathEntryHoldingAnotherProgramOfThatNameIsPassedOver() {
        let other = "/usr/local/bin/htop"
        #expect(plan(.program(["htop"]), searchPath: "/usr/local/bin:/opt/homebrew/bin", files: [other: other, Self.htop: Self.htop])
            == .success(.program(argv: [Self.htop], workingDirectory: "/work")))
    }

    @Test func aRelativePathIsCopiedFromTheProgramsDirectory() {
        let python = "/usr/local/bin/python3.12"
        #expect(plan(.program(["./venv/bin/python", "x"]), executable: python, files: ["/work/venv/bin/python": python, python: python])
            == .success(.program(argv: ["/work/venv/bin/python", "x"], workingDirectory: "/work")))
        #expect(plan(.program(["../bin/tool"]), executable: "/bin/tool", files: ["/bin/tool": "/bin/tool"])
            == .success(.program(argv: ["/bin/tool"], workingDirectory: "/work")))
        #expect(plan(.program(["./missing"]), files: [Self.htop: Self.htop]) == refusal(.notLocated))
        #expect(plan(.program(["./tool"]), cwd: nil) == refusal(.replay(.noDirectory)))
    }

    // a version manager's shim re-execs the real binary under its bare name, so no PATH entry resolves to the image
    @Test func withNoEntryResolvingToTheImageTheShellsOwnPickIsCopied() {
        let ruby = "/Users/u/.rbenv/versions/3.3.0/bin/ruby"
        let shim = "/Users/u/.rbenv/shims/ruby"
        #expect(plan(.program(["ruby", "app.rb"]), executable: ruby, searchPath: "/Users/u/.rbenv/shims:/usr/bin",
                     files: [shim: shim, "/usr/bin/ruby": "/usr/bin/ruby", ruby: ruby])
            == .success(.program(argv: [shim, "app.rb"], workingDirectory: "/work")))
        #expect(plan(.program(["./tool"]), executable: "/opt/x/tool", files: ["/work/tool": "/work/tool", "/opt/x/tool": "/opt/x/tool"])
            == .success(.program(argv: ["/work/tool"], workingDirectory: "/work")))
    }

    // macOS withholds a platform binary's environment, so every bare /usr/bin program read no PATH and was refused
    @Test func withNoReadablePathTheSystemDirectoriesAreSearchedThenTheImageIsCopied() {
        #expect(plan(.program(["tee", "out.txt"]), executable: "/usr/bin/tee", searchPath: nil, files: ["/usr/bin/tee": "/usr/bin/tee"])
            == .success(.program(argv: ["/usr/bin/tee", "out.txt"], workingDirectory: "/work")))
        #expect(plan(.program(["vimdiff", "a"]), executable: "/usr/bin/vim", searchPath: nil,
                     files: ["/usr/bin/vimdiff": "/usr/bin/vim", "/usr/bin/vim": "/usr/bin/vim"])
            == .success(.program(argv: ["/usr/bin/vimdiff", "a"], workingDirectory: "/work")))
        #expect(plan(.program(["htop"]), searchPath: nil) == .success(.program(argv: [Self.htop], workingDirectory: "/work")))
    }

    @Test(arguments: ["", "bin:/nowhere"])
    func aProgramNotFoundWhereItWasStartedIsRefusedRatherThanCopiedAsTheImage(searchPath: String?) {
        #expect(plan(.program(["htop"]), searchPath: searchPath, files: ["bin/htop": Self.htop, Self.htop: Self.htop])
            == refusal(.notLocated))
    }

    // a package upgrade removed a running codex's image, so every copy of its pane was refused
    @Test func aBareProgramWhoseImageIsGoneStartsWhatItsPathNamesNow() {
        let codex = "/opt/homebrew/bin/codex"
        #expect(plan(.program(["codex", "-c", "x"]), executable: nil, searchPath: "/nowhere:relative:/opt/homebrew/bin",
                     files: [codex: "/opt/homebrew/Caskroom/codex/2/bin/codex"])
            == .success(.program(argv: [codex, "-c", "x"], workingDirectory: "/work")))
    }

    @Test(arguments: [("htop", "/nowhere"), ("htop", nil), ("htop", ""), ("./tool", "/opt/homebrew/bin")] as [(String, String?)])
    func aProgramWhoseImageIsGoneWithNothingOnItsPathIsRefused(program: String, searchPath: String?) {
        #expect(plan(.program([program]), executable: nil, searchPath: searchPath, files: [Self.htop: Self.htop, "/work/tool": "/work/tool"])
            == refusal(.noExecutable))
    }

    @Test func aProgramWhoseImageIsGoneStillPassesTheReplayChecks() {
        let codex = "/opt/homebrew/bin/codex"
        let files = [codex: "/opt/homebrew/Caskroom/codex/2/bin/codex"]
        #expect(plan(.program(["codex"]), cwd: nil, executable: nil, files: files) == refusal(.replay(.noDirectory)))
        #expect(plan(.program(["codex", "a\\b"]), executable: nil, files: files) == refusal(.backslash))
        #expect(plan(.program(["codex"]), executable: nil, files: files, denylist: ["codex"]) == refusal(.replay(.denylisted("codex"))))
        #expect(plan(.program(["vi"]), executable: nil, files: ["/opt/homebrew/bin/vi": "/usr/bin/vim"], denylist: ["vim"])
            == refusal(.replay(.denylisted("vim"))))
    }

    @Test func aDaemonLeaderShellRunningSomethingIsRefused() {
        #expect(plan(.program(["/bin/zsh", "script.sh"]), leader: true) == refusal(.replay(.shell("zsh"))))
    }

    @Test(arguments: [["grep", "a\\.b"], ["printf", "x\\"]])
    func anArgumentWithABackslashIsRefused(argv: [String]) {
        let path = "/usr/bin/\(argv[0])"
        #expect(plan(.program(argv), executable: path, searchPath: "/usr/bin", files: [path: path]) == refusal(.backslash))
    }

    @Test func theChecksSeeBothThePathAndTheImage() {
        #expect(plan(.program(["htop"]), executable: "/odd\\dir/htop", searchPath: "/odd\\dir",
                     files: ["/odd\\dir/htop": "/odd\\dir/htop"]) == refusal(.backslash))
        #expect(plan(.program(["vi"]), executable: "/usr/bin/vim", searchPath: "/usr/bin",
                     files: ["/usr/bin/vi": "/usr/bin/vim", "/usr/bin/vim": "/usr/bin/vim"], denylist: ["vim"])
            == refusal(.replay(.denylisted("vim"))))
        #expect(plan(.program(["vimdiff"]), executable: "/usr/bin/vim", searchPath: "/usr/bin",
                     files: ["/usr/bin/vimdiff": "/usr/bin/vim", "/usr/bin/vim": "/usr/bin/vim"], denylist: ["vimdiff"])
            == refusal(.replay(.denylisted("vimdiff"))))
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
        let make = "/usr/bin/make"
        #expect(plan(.program(["make"]), cwd: nil, executable: make, searchPath: "/usr/bin", files: [make: make])
            == refusal(.replay(.noDirectory)))
    }
}
