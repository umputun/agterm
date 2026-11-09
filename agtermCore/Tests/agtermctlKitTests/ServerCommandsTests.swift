#if os(macOS)
import ArgumentParser
import CryptoKit
import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

struct ServerCommandsTests {
    private let fixture: Fixture

    init() throws { fixture = try Fixture() }

    @Test func installMapsItsTypedOptionsOntoTheConnection() throws {
        let install = try Server.Install.parse(["me@box", "-p", "2222", "-i", "/k1", "-i", "/k2", "-J", "bastion", "-F", "/cfg"])

        #expect(install.connection == TerminfoInstall.Connection(destination: "me@box", port: 2222, identities: ["/k1", "/k2"],
                                                                 jump: "bastion", config: "/cfg"))
    }

    @Test func fromNamesALocalTarball() throws {
        #expect(try Server.Install.parse(["--from", "/tmp/t.tar.gz", "box"]).source == "/tmp/t.tar.gz")
        #expect(try Server.Install.parse(["box"]).source == nil)
    }

    @Test func aLocalTarballIsInstalledFromASnapshotTheOriginalCannotChange() throws {
        let original = fixture.root.appendingPathComponent("original.tar.gz")
        let link = fixture.root.appendingPathComponent("link.tar.gz")
        try Data("release".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let effects = fixture.effects(probe: "x86_64\n", beforeUnpack: { try? Data("tampered".utf8).write(to: original) })

        #expect(try ServerInstaller(effects: effects.value).install(.init(destination: "box"), source: link.path) == 0)
        #expect(effects.calls.map(\.phase) == ["probe", "unpack", "installer"])
        #expect(effects.calls[1].detail == "tarball")
    }

    @Test func aMismatchedLocalTarballNeverUnpacks() throws {
        let local = fixture.root.appendingPathComponent("local.tar.gz")
        try Data("other".utf8).write(to: local)
        let effects = fixture.effects(probe: "x86_64\n")

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box"), source: local.path) }
        #expect(effects.calls.map(\.phase) == ["probe"])
    }

    @Test func anOversizeLocalTarballIsRefusedBeforeItIsRead() throws {
        let local = fixture.root.appendingPathComponent("huge.tar.gz")
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let handle = try FileHandle(forWritingTo: local)
        try handle.truncate(atOffset: UInt64(ServerInstall.downloadLimit + 1))
        try handle.close()
        let effects = fixture.effects(probe: "x86_64\n")

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box"), source: local.path) }
        #expect(effects.calls.map(\.phase) == ["probe"])
    }

    @Test(arguments: ["absent.tar.gz", ""])
    func anUnreadableLocalTarballIsRefused(_ name: String) {
        let effects = fixture.effects(probe: "x86_64\n")
        let path = fixture.root.appendingPathComponent(name).path

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box"), source: path) }
        #expect(effects.calls.map(\.phase) == ["probe"])
    }

    @Test func installIsNotAControlCommand() throws {
        #expect(!(try Agtermctl.parseAsRoot(["server", "install", "box"]) is any RequestCommand))
    }

    @Test func aBadDestinationParsesAndIsRefusedAtRunWithoutTouchingAnything() throws {
        _ = try Server.Install.parse(["--", "-oProxyCommand=x"])
        let effects = fixture.effects(probe: "x86_64\n")

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "-oProxyCommand=x")) }
        #expect(effects.calls.isEmpty)
    }

    @Test func aMatchingTarballIsUnpackedThenInstalled() throws {
        let effects = fixture.effects(probe: "x86_64\n")

        let code = try ServerInstaller(effects: effects.value).install(.init(destination: "box"))

        #expect(code == 0)
        #expect(effects.calls.map(\.phase) == ["probe", "download", "unpack", "installer"])
        #expect(effects.calls[1].detail
            == "https://github.com/umputun/agterm/releases/download/v1.2.3/agterm-server-1.2.3-linux-x86_64.tar.gz")
        #expect(effects.calls[2].argv.last == "sh -c '\(ServerInstall.unpackScript)'")
        #expect(effects.calls[2].detail == "tarball")
        #expect(effects.printed == ["installed agterm-server 1.2.3 on box"])
    }

    @Test func theDownloadIsRemovedWhateverHappens() throws {
        let effects = fixture.effects(probe: "x86_64\n", installer: .exited(1))

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box")) }
        let file = try #require(effects.downloadedFile)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test func aMismatchNeverUnpacks() throws {
        let effects = fixture.effects(probe: "x86_64\n", body: "tampered")

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box")) }
        #expect(effects.calls.map(\.phase) == ["probe", "download"])
    }

    @Test func incompleteHooksExit3() throws {
        let effects = fixture.effects(probe: "aarch64\n", installer: .exited(3))

        #expect(try ServerInstaller(effects: effects.value).install(.init(destination: "box")) == 3)
        #expect(effects.printed == ["installed agterm-server 1.2.3 on box; the agent hooks are incomplete"])
    }

    @Test(arguments: [ForegroundSpawn.Outcome.exited(1), .exited(255), .signaled(9)])
    func aFailedInstallerIsARefusal(_ outcome: ForegroundSpawn.Outcome) {
        let effects = fixture.effects(probe: "x86_64\n", installer: outcome)

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box")) }
    }

    @Test func aFailedUnpackNeverRunsTheInstaller() {
        let effects = fixture.effects(probe: "x86_64\n", unpack: .exited(2))

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box")) }
        #expect(effects.calls.map(\.phase) == ["probe", "download", "unpack"])
    }

    @Test func anUnsupportedArchitectureStopsBeforeTheDownload() {
        let effects = fixture.effects(probe: "riscv64\n")

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box")) }
        #expect(effects.calls.map(\.phase) == ["probe"])
    }

    @Test func aFailedProbeStopsThere() {
        let effects = fixture.effects(probe: "x86_64\n", probeOutcome: .exited(255))

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box")) }
        #expect(effects.calls.map(\.phase) == ["probe"])
    }

    @Test func aFailedDownloadNeverUnpacks() {
        let effects = fixture.effects(probe: "x86_64\n", downloadFails: true)

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box")) }
        #expect(effects.calls.map(\.phase) == ["probe", "download"])
    }

    @Test(arguments: [Fixture.Bundle.none, .noChecksumFile, .noEntryForTheAsset])
    func aBuildWithoutAUsableChecksumFileIsRefusedBeforeTheDownload(_ bundle: Fixture.Bundle) {
        let effects = fixture.effects(probe: "x86_64\n", bundle: bundle)

        #expect(throws: SocketClientError.self) { try ServerInstaller(effects: effects.value).install(.init(destination: "box")) }
        #expect(!effects.calls.map(\.phase).contains("download"))
    }

    @Test(arguments: ["http://example.com/x", "file:///etc/hosts"])
    func theDownloaderRefusesAnythingButHttps(_ url: String) {
        #expect(throws: ReleaseDownload.Refused.self) {
            try ReleaseDownload.fetch(URL(string: url)!, to: fixture.root.appendingPathComponent("d"), limit: 10)
        }
    }

    @Test(arguments: [404, 500, 304])
    func theDownloaderRefusesANonSuccessAnswer(_ status: Int) throws {
        let (download, task, file) = try fixture.download(limit: 10)
        let response = try #require(HTTPURLResponse(url: task.originalRequest!.url!, statusCode: status, httpVersion: nil, headerFields: nil))
        let decision = Decision()

        download.urlSession(URLSession.shared, dataTask: task, didReceive: response) { decision.value = $0 }

        #expect(decision.value == .cancel)
        #expect(download.failure != nil)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func theDownloaderStopsWritingAtTheLimit() throws {
        let (download, task, file) = try fixture.download(limit: 10)

        download.urlSession(URLSession.shared, dataTask: task, didReceive: Data("123456".utf8))
        download.urlSession(URLSession.shared, dataTask: task, didReceive: Data("789012".utf8))

        #expect(download.failure != nil)
        #expect(try Data(contentsOf: file) == Data("123456".utf8))
    }

    @Test func theDownloaderRefusesARedirectOffHttps() throws {
        let (download, task, _) = try fixture.download(limit: 10)
        let response = try #require(HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil))
        let followed = Decision()

        download.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "http://example.com/x")!)) { followed.request = $0 }

        #expect(followed.request == nil)
        #expect(download.failure != nil)
    }

    // ssh reads a password or host-key answer from /dev/tty, which stops a background process group with SIGTTIN
    @Test func theProbeCanReadTheTerminalItRunsIn() throws {
        let client = try fixture.bundledClient()
        let ssh = try fixture.ttySSH()
        let run = try fixture.run("/usr/bin/script", ["-q", "/dev/null", client, "server", "install", "box"],
                                  stdin: "yes\n", path: ssh.deletingLastPathComponent().path)

        #expect(run.finished, "agtermctl did not finish within 20 seconds: \(run.output)")
        #expect(run.output.contains("unsupported host architecture 'riscv64'"), Comment(rawValue: run.output))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("tty.answer"), encoding: .utf8) == "yes\n")
    }
}

final class Decision: @unchecked Sendable {
    var value: URLSession.ResponseDisposition?
    var request: URLRequest?
}

final class RecordedEffects {
    struct Call {
        let phase: String
        let argv: [String]
        let detail: String
    }

    var calls: [Call] = []
    var printed: [String] = []
    var downloadedFile: URL?
    var value: ServerInstaller.Effects!
}

final class Fixture {
    enum Bundle: Sendable { case release, none, noChecksumFile, noEntryForTheAsset }

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("server-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func effects(probe: String, probeOutcome: ForegroundSpawn.Outcome = .exited(0), body: String = "release",
                 downloadFails: Bool = false, unpack: ForegroundSpawn.Outcome = .exited(0),
                 installer: ForegroundSpawn.Outcome = .exited(0), bundle: Bundle = .release,
                 beforeUnpack: (() -> Void)? = nil) -> RecordedEffects {
        let recorded = RecordedEffects()
        let app = try? makeBundle(bundle)
        recorded.value = ServerInstaller.Effects(
            bundle: { app },
            capture: { argv in
                recorded.calls.append(.init(phase: "probe", argv: argv, detail: ""))
                return (probeOutcome, Data(probe.utf8))
            },
            run: { argv, input in
                let unpacking = argv.last?.hasPrefix("sh -c") == true
                if unpacking { beforeUnpack?() }
                var detail = ""
                if case .file(let path) = input, (try? String(contentsOfFile: path, encoding: .utf8)) == body { detail = "tarball" }
                recorded.calls.append(.init(phase: unpacking ? "unpack" : "installer", argv: argv, detail: detail))
                return unpacking ? unpack : installer
            },
            download: { url, file, _ in
                recorded.calls.append(.init(phase: "download", argv: [], detail: url.absoluteString))
                recorded.downloadedFile = file
                if downloadFails { throw ReleaseDownload.Refused(description: "the server answered 404") }
                try Data(body.utf8).write(to: file)
            },
            print: { recorded.printed.append($0) })
        return recorded
    }

    private func makeBundle(_ kind: Bundle) throws -> URL? {
        guard kind != .none else { return nil }
        let app = root.appendingPathComponent("agterm.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.2.3"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        guard kind != .noChecksumFile else { return app }
        let digest = SHA256.hash(data: Data("release".utf8)).map { String(format: "%02x", $0) }.joined()
        let names = kind == .noEntryForTheAsset ? ["agterm-server-9.9.9-linux-x86_64.tar.gz"]
            : ["agterm-server-1.2.3-linux-aarch64.tar.gz", "agterm-server-1.2.3-linux-x86_64.tar.gz"]
        try names.map { "\(digest)  \($0)\n" }.joined()
            .write(to: resources.appendingPathComponent(ServerInstall.checksumFile), atomically: true, encoding: .utf8)
        return app
    }

    func bundledClient() throws -> String {
        let app = try #require(try makeBundle(.release))
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/agtermctl")
        let client = macOS.appendingPathComponent("agtermctl")
        try FileManager.default.copyItem(at: built, to: client)
        return client.path
    }

    func download(limit: Int) throws -> (ReleaseDownload, URLSessionDataTask, URL) {
        let file = root.appendingPathComponent("download-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.com/asset")!)
        return (ReleaseDownload(handle: try FileHandle(forWritingTo: file), limit: limit), task, file)
    }

    func ttySSH() throws -> URL {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let ssh = bin.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        IFS= read -r answer < /dev/tty
        printf '%s\\n' "$answer" > '\(root.appendingPathComponent("tty.answer").path)'
        echo riscv64
        """.writeExecutable(to: ssh)
        return ssh
    }

    func run(_ executable: String, _ arguments: [String], stdin: String, path: String) throws -> (finished: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "\(path):/usr/bin:/bin", "HOME": root.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        let finished = exited.wait(timeout: .now() + 20) == .success
        if !finished {
            // script's child leads the pty session: killing its group and script's hangs up and continues a stopped job
            for pid in childPIDs(of: process.processIdentifier) { kill(-pid, SIGKILL) }
            kill(-process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (finished, String(decoding: data, as: UTF8.self))
    }

    private func childPIDs(of parent: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(parent)]
        let output = Pipe()
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }
}
#endif
