import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

struct ZmxRunnerTests {
    @Test func withoutAUserManagerDaemonsStartDirectly() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }

        #expect(ServerPlacement.detect(environment: ["XDG_RUNTIME_DIR": scratch.runtime, "PATH": scratch.bin]) == .direct)
        #expect(ServerPlacement.direct.prefix(for: "agterm-x").isEmpty)
    }

    @Test func aUserManagerPutsEachDaemonInItsOwnScope() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(atPath: scratch.runtime + "/systemd", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: scratch.runtime + "/systemd/private", contents: Data())
        let run = scratch.bin + "/systemd-run"
        FileManager.default.createFile(atPath: run, contents: Data(), attributes: [.posixPermissions: 0o755])

        let placement = ServerPlacement.detect(environment: ["XDG_RUNTIME_DIR": scratch.runtime, "PATH": "/nowhere:" + scratch.bin])

        #expect(placement == .systemdScope(systemdRun: run))
        let prefix = placement.prefix(for: "agterm-abc")
        #expect(prefix.prefix(6) == [run, "--user", "--scope", "--quiet", "--collect", prefix[5]])
        #expect(prefix[5].hasPrefix("--unit=agterm-abc-") && prefix[5].hasSuffix(".scope"))
        #expect(prefix.last == "--")
        #expect(placement.prefix(for: "agterm-abc")[5] != prefix[5])
    }

    @Test func aRunnerCreatesThroughAttachDetachedInTheLaunchDirectory() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let log = scratch.root + "/zmx.log"
        let fake = scratch.bin + "/fake-zmx"
        try writeExecutable(fake, "#!/bin/sh\necho \"$PWD|$ZMX_DIR|$*|$MARK\" >> \(log)\n")
        let runner = ProcessZmxRunner(zmxPath: fake, socketDirectory: scratch.runtime + "/zmx", placement: .direct,
                                      baseEnvironment: [:])

        try runner.create(PaneLaunch(name: "agterm-p", argv: ["/bin/zsh", "-lic", "true"],
                                     environment: ["ZMX_DIR": scratch.runtime + "/zmx", "MARK": "m"], directory: scratch.root))

        let line = try String(contentsOfFile: log, encoding: .utf8).trimmingCharacters(in: .newlines)
        let fields = line.split(separator: "|").map(String.init)
        #expect(fields.count == 4)
        #expect(realPath(fields[0]) == realPath(scratch.root))
        #expect(fields.dropFirst() == ["\(scratch.runtime)/zmx", "attach --detached agterm-p /bin/zsh -lic true", "m"])
    }

    @Test func aFailedCreateCarriesZmxsMessage() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let fake = scratch.bin + "/fake-zmx"
        try writeExecutable(fake, "#!/bin/sh\necho 'error: session \"x\" exists' >&2\nexit 1\n")
        let runner = ProcessZmxRunner(zmxPath: fake, socketDirectory: scratch.runtime, placement: .direct, baseEnvironment: [:])

        #expect(throws: ZmxRunnerError.failed("error: session \"x\" exists")) {
            try runner.create(PaneLaunch(name: "x", argv: [], environment: [:], directory: scratch.root))
        }
    }

    @Test(arguments: ["printf 'name=agterm-a\\tclients=0\\nclients=0\\n'", "printf 'name=agterm-a\\tclients=0\\n'; exit 1"])
    func aListingThatIsNotWholeFails(script: String) throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let fake = scratch.bin + "/fake-zmx"
        try writeExecutable(fake, "#!/bin/sh\n\(script)\n")
        let runner = ProcessZmxRunner(zmxPath: fake, socketDirectory: scratch.runtime, placement: .direct, baseEnvironment: [:])

        #expect(throws: (any Error).self) { try runner.list() }
    }

    // a listing read cut short at the collector's grace parsed as no daemons, and the observer ended live sessions
    @Test func aListingWhoseOutputNeverEndedFails() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let hold = scratch.root + "/hold"
        FileManager.default.createFile(atPath: hold, contents: Data())
        let fake = scratch.bin + "/fake-zmx"
        try writeExecutable(fake, "#!/bin/sh\n(while [ -e \(hold) ]; do sleep 0.05; done; printf 'name=agterm-a\\tclients=0\\n') &\n")
        let runner = ProcessZmxRunner(zmxPath: fake, socketDirectory: scratch.runtime, placement: .direct, baseEnvironment: [:])

        #expect(throws: (any Error).self) { try runner.list() }
    }

    @Test func aScreenWhoseOutputNeverEndedIsNone() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let hold = scratch.root + "/hold"
        FileManager.default.createFile(atPath: hold, contents: Data())
        let fake = scratch.bin + "/fake-zmx"
        try writeExecutable(fake, "#!/bin/sh\nprintf '1 80 24 0 0 0\\npartial\\n'\n(while [ -e \(hold) ]; do sleep 0.05; done; echo rest) &\n")
        let runner = ProcessZmxRunner(zmxPath: fake, socketDirectory: scratch.runtime, placement: .direct, baseEnvironment: [:])

        #expect(runner.screen("agterm-a", all: false) == nil)
    }

    @Test func anEmptyListingIsNoDaemons() throws {
        let scratch = try ServerScratch()
        defer { scratch.remove() }
        let fake = scratch.bin + "/fake-zmx"
        try writeExecutable(fake, "#!/bin/sh\necho 'no sessions found' >&2\n")
        let runner = ProcessZmxRunner(zmxPath: fake, socketDirectory: scratch.runtime, placement: .direct, baseEnvironment: [:])

        #expect(try runner.list().isEmpty)
    }
}

private func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
