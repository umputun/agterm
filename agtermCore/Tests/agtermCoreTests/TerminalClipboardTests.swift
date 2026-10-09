import Foundation
import Testing
@testable import agtermCore

struct TerminalClipboardTests {
    private static let daemon = "agterm-357e181888f34450b5c225bd00239b9b"
    private static let live = ["ZMX_SESSION": daemon, "ZMX_DIR": "/tmp/agterm-zmx-1"]

    private let fixture: Fixture

    init() throws { fixture = try Fixture() }

    @Test func sequenceIsAnOSC52ClipboardWriteEndingInBEL() throws {
        let sequence = try TerminalClipboard.sequence(for: Data("héllo\n".utf8))

        #expect(sequence == Data("\u{1b}]52;c;aMOpbGxvCg==\u{07}".utf8))
    }

    @Test func emptyTextIsRefused() {
        #expect(throws: TerminalClipboard.Failure.emptyText) { try TerminalClipboard.sequence(for: Data()) }
    }

    @Test func textEncodingToExactlyTheLimitIsAccepted() throws {
        let text = Data(count: TerminalClipboard.maxEncodedBytes / 4 * 3)

        #expect(try TerminalClipboard.sequence(for: text).count == TerminalClipboard.maxEncodedBytes + 8)
    }

    @Test func textEncodingPastTheLimitIsRefused() {
        let text = Data(count: TerminalClipboard.maxEncodedBytes / 4 * 3 + 1)

        #expect(throws: TerminalClipboard.Failure.tooLarge(encodedBytes: TerminalClipboard.maxEncodedBytes + 4)) {
            try TerminalClipboard.sequence(for: text)
        }
    }

    @Test func targetIsTheDaemonAndDirectoryThePaneWasGiven() throws {
        #expect(try TerminalClipboard.target(environment: Self.live)
            == TerminalClipboard.Target(session: Self.daemon, directory: "/tmp/agterm-zmx-1"))
    }

    @Test(arguments: [
        [:],
        ["ZMX_SESSION": daemon],
        ["ZMX_DIR": "/tmp/agterm-zmx-1"],
        ["ZMX_SESSION": "", "ZMX_DIR": "/tmp/agterm-zmx-1"],
        ["ZMX_SESSION": daemon, "ZMX_DIR": ""],
        ["ZMX_SESSION": "notes", "ZMX_DIR": "/tmp/agterm-zmx-1"],
        ["ZMX_SESSION": "agterm-notes", "ZMX_DIR": "/tmp/agterm-zmx-1"],
    ])
    func anEnvironmentThatNamesNoAgtermDaemonIsNotALivePane(_ environment: [String: String]) {
        #expect(throws: TerminalClipboard.Failure.notLivePane) { try TerminalClipboard.target(environment: environment) }
    }

    @Test func zmxIsTheExecutableBesideTheClient() throws {
        let bundle = try fixture.bundle(withZmx: true)

        #expect(try TerminalClipboard.zmxPath(clientPath: bundle.client) == bundle.zmx)
    }

    @Test func aBundleWithoutZmxReportsWhereItLooked() throws {
        let bundle = try fixture.bundle(withZmx: false)

        #expect(throws: TerminalClipboard.Failure.zmxNotFound(path: bundle.zmx)) {
            try TerminalClipboard.zmxPath(clientPath: bundle.client)
        }
    }

    @Test func anUnresolvedClientPathFindsNoZmx() {
        #expect(throws: TerminalClipboard.Failure.zmxNotFound(path: nil)) { try TerminalClipboard.zmxPath(clientPath: nil) }
    }

    @Test func copyPrintsTheSequenceIntoThePanesDaemonOnStdin() throws {
        let zmx = try fixture.fakeZmx(exitCode: 0)

        try TerminalClipboard.copy(Data("hello".utf8), clientPath: nil, environment: Self.live, zmx: zmx)

        #expect(try fixture.arguments() == ["print", Self.daemon])
        #expect(try fixture.stdin() == Data("\u{1b}]52;c;aGVsbG8=\u{07}".utf8))
    }

    @Test func copyClearsTheSessionVariablesAndKeepsTheSocketDirectory() throws {
        let zmx = try fixture.fakeZmx(exitCode: 0)
        let environment = Self.live.merging(["ZMX_SESSION_PREFIX": "work-"]) { _, new in new }

        try TerminalClipboard.copy(Data("hello".utf8), clientPath: nil, environment: environment, zmx: zmx)

        #expect(try fixture.environment() == ["ZMX_DIR=/tmp/agterm-zmx-1", "ZMX_SESSION=", "ZMX_SESSION_PREFIX="])
    }

    @Test func aFailedPrintCarriesItsStatusAndStderr() throws {
        let zmx = try fixture.fakeZmx(exitCode: 3, stderr: "session not found")

        #expect(throws: TerminalClipboard.Failure.printFailed(status: 3, stderr: "session not found\n")) {
            try TerminalClipboard.copy(Data("hello".utf8), clientPath: nil, environment: Self.live, zmx: zmx)
        }
    }

    @Test func aZmxThatExitsWithoutReadingStdinStillReportsItsStatus() throws {
        let zmx = try fixture.fakeZmx(exitCode: 4, readsStdin: false)
        let text = Data(count: 1024 * 1024)

        #expect(throws: TerminalClipboard.Failure.printFailed(status: 4, stderr: "")) {
            try TerminalClipboard.copy(text, clientPath: nil, environment: Self.live, zmx: zmx)
        }
    }

    @Test func aPaneThatIsNotLiveNeverStartsZmx() throws {
        let zmx = try fixture.fakeZmx(exitCode: 0)

        #expect(throws: TerminalClipboard.Failure.notLivePane) {
            try TerminalClipboard.copy(Data("hello".utf8), clientPath: nil, environment: [:], zmx: zmx)
        }
        #expect(!fixture.zmxWasCalled())
    }
}

private struct Fixture {
    let root: URL
    private var args: URL { root.appendingPathComponent("args") }
    private var input: URL { root.appendingPathComponent("stdin") }
    private var env: URL { root.appendingPathComponent("env") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-clipboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func bundle(withZmx: Bool) throws -> (client: String, zmx: String) {
        let macOS = root.appendingPathComponent("agterm.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let client = macOS.appendingPathComponent("agtermctl")
        try Data().write(to: client)
        let zmx = macOS.appendingPathComponent("zmx")
        if withZmx { try script(at: zmx, body: "exit 0") }
        return (client.path, zmx.path)
    }

    func fakeZmx(exitCode: Int32, stderr: String? = nil, readsStdin: Bool = true) throws -> String {
        let read = readsStdin ? "cat > '\(input.path)'" : ""
        let complain = stderr.map { "printf '%s\\n' '\($0)' >&2" } ?? ""
        return try script(at: root.appendingPathComponent("zmx"), body: """
        printf '%s\\n' "$@" > '\(args.path)'
        env | grep '^ZMX_' | sort > '\(env.path)'
        \(read)
        \(complain)
        exit \(exitCode)
        """)
    }

    func arguments() throws -> [String] { try lines(of: args) }

    func environment() throws -> [String] { try lines(of: env) }

    func stdin() throws -> Data { try Data(contentsOf: input) }

    func zmxWasCalled() -> Bool { FileManager.default.fileExists(atPath: args.path) }

    private func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @discardableResult
    private func script(at file: URL, body: String) throws -> String {
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }
}
