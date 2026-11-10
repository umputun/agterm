import Foundation
import Testing
@testable import agtermCore

struct ServerInstallTests {
    private let digest = String(repeating: "ab", count: 32)

    @Test func theAssetAndItsURLFollowTheReleaseNaming() {
        #expect(ServerInstall.assetName(version: "1.2.3", architecture: "x86_64") == "agterm-server-1.2.3-linux-x86_64.tar.gz")
        #expect(ServerInstall.downloadURL(version: "1.2.3", architecture: "aarch64").absoluteString
            == "https://github.com/umputun/agterm/releases/download/v1.2.3/agterm-server-1.2.3-linux-aarch64.tar.gz")
    }

    @Test(arguments: ["aarch64\n", "x86_64", "  x86_64 \r\n"])
    func aSupportedArchitectureIsRead(_ output: String) throws {
        #expect(ServerInstall.architectures.contains(try ServerInstall.architecture(probeOutput: Data(output.utf8))))
    }

    @Test(arguments: ["riscv64\n", "", "arm64", "x86_64\nextra"])
    func anyOtherProbeOutputIsRefused(_ output: String) {
        #expect(throws: ServerInstall.Failure.self) { try ServerInstall.architecture(probeOutput: Data(output.utf8)) }
    }

    @Test func theChecksumLineForTheAssetIsReturnedLowercase() throws {
        let other = String(repeating: "cd", count: 32)
        let text = "\(other)  agterm-server-1.2.3-linux-aarch64.tar.gz\n\(digest.uppercased())  agterm-server-1.2.3-linux-x86_64.tar.gz\n"

        #expect(try ServerInstall.checksum(for: "agterm-server-1.2.3-linux-x86_64.tar.gz", in: text) == digest)
    }

    @Test func aMissingEntryIsAnError() {
        #expect(throws: ServerInstall.Failure.checksumMissing(asset: "b.tar.gz")) {
            try ServerInstall.checksum(for: "b.tar.gz", in: "\(digest)  a.tar.gz\n")
        }
    }

    @Test func aDuplicateEntryIsAnError() {
        #expect(throws: ServerInstall.Failure.checksumDuplicate(asset: "a.tar.gz")) {
            try ServerInstall.checksum(for: "a.tar.gz", in: "\(digest)  a.tar.gz\n\(digest)  a.tar.gz\n")
        }
    }

    @Test(arguments: [
        "abc  a.tar.gz\n",
        "\(String(repeating: "zz", count: 32))  a.tar.gz\n",
        "\(String(repeating: "ab", count: 32)) a.tar.gz\n",
        "\(String(repeating: "ab", count: 32))\n",
    ])
    func aMalformedLineIsAnErrorEvenBesideAGoodOne(_ bad: String) {
        #expect(throws: ServerInstall.Failure.self) {
            try ServerInstall.checksum(for: "a.tar.gz", in: "\(digest)  a.tar.gz\n" + bad)
        }
    }

    @Test func everySshPhaseSharesTerminfosConnectionPrefix() throws {
        let connection = TerminfoInstall.Connection(destination: "me@box", port: 2222, identities: ["/k"], jump: "bastion", config: "/cfg")
        let prefix = try TerminfoInstall.sshCommand(connection, ssh: "ssh")

        #expect(try ServerInstall.probeCommand(connection) == prefix + ["uname -m"])
        #expect(try ServerInstall.unpackCommand(connection) == prefix + ["sh -c '\(ServerInstall.unpackScript)'"])
        #expect(try ServerInstall.installerCommand(connection) == prefix + [#"bash "$HOME/.local/lib/agterm-server/install.sh""#])
        #expect(prefix.contains("StdinNull=no") && !prefix.contains("BatchMode=yes"))
    }

    @Test func anOptionLookingDestinationIsRefused() {
        #expect(throws: TerminfoInstall.Failure.invalidDestination) {
            try ServerInstall.probeCommand(TerminfoInstall.Connection(destination: "-oProxyCommand=x"))
        }
    }

    @Test func theRemoteStringsAreTheOnesTheDeveloperScriptSends() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/install-server.sh")
        let text = try String(contentsOf: script, encoding: .utf8)

        #expect(text.contains("unpack='\(ServerInstall.unpackScript)'\n"))
        #expect(text.contains("'\(ServerInstall.installerCommand)'"))
        #expect(!ServerInstall.unpackScript.contains("'") && !ServerInstall.unpackScript.contains("\n"))
    }

    #if os(macOS)
    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/tcsh"])
    func theUnpackSwapsInTheTarballUnderEveryLoginShell(_ shell: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("server-unpack-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = try #require(ServerInstall.unpackCommand(TerminfoInstall.Connection(destination: "box")).last)

        for (name, body) in [("old", "first"), ("install.sh", "second")] {
            let stage = root.appendingPathComponent("stage-\(name)")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: stage.appendingPathComponent(name))
            let tarball = root.appendingPathComponent("\(name).tar.gz")
            #expect(try Self.exec("/usr/bin/tar", ["-C", stage.path, "-czf", tarball.path, "."], stdin: nil, home: home) == 0)
            #expect(try Self.exec(shell, ["-c", remote], stdin: tarball, home: home) == 0)
        }

        let lib = home.appendingPathComponent(".local/lib")
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.path) == ["agterm-server"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.appendingPathComponent("agterm-server").path) == ["install.sh"])
    }

    private static func exec(_ executable: String, _ arguments: [String], stdin: URL?, home: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        if let stdin { process.standardInput = try FileHandle(forReadingFrom: stdin) }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    #endif

    @Test(arguments: [(ForegroundSpawn.Outcome.exited(0), Int32(0)), (.exited(3), 3), (.exited(1), 1), (.exited(255), 1), (.signaled(9), 1)])
    func theInstallerOutcomeMapsToTheCommandsExitCode(_ outcome: ForegroundSpawn.Outcome, _ code: Int32) {
        #expect(ServerInstall.exitCode(outcome) == code)
    }
}
