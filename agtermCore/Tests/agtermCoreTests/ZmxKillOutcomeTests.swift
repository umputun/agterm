import Testing
@testable import agtermCore

struct ZmxKillOutcomeTests {
    private let name = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    @Test(arguments: [
        ("killed session agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", ZmxKillOutcome.killed),
        ("cleaned up stale session agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", .staleSocket),
        ("failed to kill session=agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: SessionUnresponsive\n",
         .failed("failed to kill session=agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: SessionUnresponsive")),
        ("", .failed("no output")),
        ("not killed session agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
         .failed("not killed session agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
        ("killed session agterm-other\n", .failed("killed session agterm-other")),
    ])
    func onlyAnExactConfirmationLineForTheNameIsAKill(_ output: String, _ expected: ZmxKillOutcome) {
        #expect(ZmxKillOutcome.parse(output, name: name) == expected)
    }
}
