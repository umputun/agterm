import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct ClipboardCommandsTests {
    @Test func setTakesItsTextAsTheArgument() throws {
        #expect(try Clipboard.Set.parse(["hello world"]).text == "hello world")
    }

    @Test func setWithoutAnArgumentLeavesTheTextToStandardInput() throws {
        #expect(try Clipboard.Set.parse([]).text == nil)
    }

    @Test(arguments: ["--force", "- item one", "-1"])
    func setTakesDashLeadingTextOnlyAfterATerminator(_ text: String) throws {
        #expect(throws: (any Error).self) { try Clipboard.Set.parse([text]) }
        #expect(try Clipboard.Set.parse(["--", text]).text == text)
    }

    @Test(arguments: [["one", "two"], ["--socket", "/tmp/s"], ["--target", "active"], ["--json"]])
    func setRefusesASecondArgumentAndEveryControlOption(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try Clipboard.Set.parse(arguments) }
    }

    @Test func setIsNotAControlCommand() throws {
        #expect(!(try Agtermctl.parseAsRoot(["clipboard", "set", "hello"]) is any RequestCommand))
    }

    @Test(arguments: [
        (TerminalClipboard.Failure.emptyText, "nothing to copy"),
        (.tooLarge(encodedBytes: 9_000_000),
         "text is too large to copy through the terminal: 9000000 bytes encoded, the limit is 8388544"),
        (.notLivePane, "this pane has no zmx daemon; run it in a main or split pane started under Live sessions"),
        (.zmxNotFound(path: nil), "no zmx next to this agtermctl"),
        (.zmxNotFound(path: "/x/zmx"), "no zmx next to this agtermctl; looked for /x/zmx"),
        (.printFailed(status: 1, stderr: "session not found\n"), "zmx print exited 1: session not found"),
    ])
    func everyFailureHasItsOwnMessage(_ failure: TerminalClipboard.Failure, _ message: String) {
        #expect(Clipboard.Set.message(for: failure) == message)
    }
}
