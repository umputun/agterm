#if os(macOS)
import ArgumentParser
import CryptoKit
import Foundation
import agtermCore

// MARK: - server

/// Server groups the agterm-server commands. Local-only, like `terminfo`: it runs ssh and a download on this Mac and never opens the control socket.
/// macOS only, since it installs the release this app shipped with.
struct Server: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "agterm-server on Linux hosts.",
        subcommands: [Install.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install or upgrade agterm-server on a Linux host over ssh.",
            discussion: """
            Installs the agterm-server release matching this app's version: asks the host for its architecture \
            (aarch64 or x86_64), downloads that release tarball from GitHub, checks it against the sha256 the app \
            was built with, unpacks it into ~/.local/lib/agterm-server and runs its installer, which sets up the \
            systemd user service, enables linger and installs the agent hooks. Running it again upgrades in place.

            The connection is interactive, as with terminfo install: a password or host-key prompt is answered on \
            this terminal, and other settings belong in ~/.ssh/config. Exits 0 when installed, 3 when installed but \
            the agent hooks are incomplete, and 1 on installation failure, with the reason on stderr. A development build \
            has no release to install; scripts/install-server.sh installs from a source tree.
            """)
        @Argument(help: "The host, as ssh would take it: host, user@host, or an alias from ~/.ssh/config.")
        var destination: String
        @Option(name: .short, help: ArgumentHelp("Port to connect to on the remote host.", valueName: "port"))
        var port: Int?
        @Option(name: .short, help: ArgumentHelp("Identity file for public key authentication. Repeat to offer several.",
                                                 valueName: "file"))
        var identity: [String] = []
        @Option(name: .customShort("J"), help: ArgumentHelp("Jump host, as ssh -J takes it.", valueName: "host"))
        var jump: String?
        @Option(name: .customShort("F"), help: ArgumentHelp("Per-user ssh configuration file.", valueName: "file"))
        var config: String?

        var connection: TerminfoInstall.Connection {
            TerminfoInstall.Connection(destination: destination, port: port, identities: identity, jump: jump,
                                       config: config)
        }

        // a bad destination is a refusal with exit 1 like every other, so it is checked in run, not validate
        func run() throws {
            let code = try ServerInstaller(effects: .live).install(connection)
            if code != 0 { throw ExitCode(code) }
        }
    }
}

/// ServerInstaller runs `server install`'s steps over injectable effects, so tests drive every refusal and the
/// order of the ssh phases without ssh or the network. Refusals throw `SocketClientError`, which exits 1.
struct ServerInstaller {
    struct Effects {
        /// bundle is the app bundle holding this CLI, nil when it is not inside one.
        var bundle: () -> URL?
        /// capture runs ssh with stdin from /dev/null and returns its stdout.
        var capture: (_ argv: [String]) throws -> (outcome: ForegroundSpawn.Outcome, output: Data)
        /// run runs ssh with the given stdin and the terminal's stdout.
        var run: (_ argv: [String], _ input: ForegroundSpawn.Input) throws -> ForegroundSpawn.Outcome
        /// download fetches `url` into `file`, refusing more than `limit` bytes.
        var download: (_ url: URL, _ file: URL, _ limit: Int) throws -> Void
        var print: (String) -> Void

        static var live: Effects { Effects(
            bundle: {
                guard let client = Version.clientPath() else { return nil }
                let contents = URL(fileURLWithPath: client).deletingLastPathComponent().deletingLastPathComponent()
                return contents.lastPathComponent == "Contents" ? contents.deletingLastPathComponent() : nil
            },
            capture: { try ForegroundSpawn.capture($0, environment: ProcessInfo.processInfo.environment) },
            run: { try ForegroundSpawn.run($0, input: $1, environment: ProcessInfo.processInfo.environment) },
            download: { try ReleaseDownload.fetch($0, to: $1, limit: $2) },
            print: { Swift.print($0) }) }
    }

    let effects: Effects

    /// install returns 0 or 3 once the host's installer ran, and throws for every refusal and failure.
    func install(_ connection: TerminfoInstall.Connection) throws -> Int32 {
        let probe: [String]
        do {
            probe = try ServerInstall.probeCommand(connection)
        } catch {
            throw SocketClientError("destination must be a host, user@host or an ssh alias, not '\(connection.destination)'")
        }
        let release = try releaseInfo()

        let architecture = try probeArchitecture(probe)
        let asset = ServerInstall.assetName(version: release.version, architecture: architecture)
        let expected: String
        do {
            expected = try ServerInstall.checksum(for: asset, in: release.checksums)
        } catch {
            throw SocketClientError("this app's \(ServerInstall.checksumFile) has no usable entry for \(asset): \(error)")
        }

        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(asset)
        let url = ServerInstall.downloadURL(version: release.version, architecture: architecture)
        do {
            try effects.download(url, file, ServerInstall.downloadLimit)
        } catch {
            throw SocketClientError("could not download \(url.absoluteString): \(error)")
        }
        let actual = try sha256(of: file)
        guard actual == expected else {
            throw SocketClientError("\(asset) does not match the sha256 this app was built with; nothing was installed")
        }

        let unpacked = try spawn { try effects.run(ServerInstall.unpackCommand(connection), .file(file.path)) }
        guard unpacked == .exited(0) else { throw SocketClientError("unpacking on \(connection.destination) failed: \(unpacked)") }
        let installed = try spawn { try effects.run(ServerInstall.installerCommand(connection), .nothing) }
        let code = ServerInstall.exitCode(installed)
        switch code {
        case 0: effects.print("installed agterm-server \(release.version) on \(connection.destination)")
        case 3: effects.print("installed agterm-server \(release.version) on \(connection.destination); the agent hooks are incomplete")
        default: throw SocketClientError("the installer on \(connection.destination) failed: \(installed)")
        }
        return code
    }

    private func releaseInfo() throws -> (version: String, checksums: String) {
        let refusal = "this agtermctl is not inside a release agterm.app; scripts/install-server.sh installs from a source tree"
        guard let bundle = effects.bundle(), let identity = AppIdentity.installed(bundleURL: bundle) else {
            throw SocketClientError(refusal)
        }
        let file = bundle.appendingPathComponent("Contents/Resources/\(ServerInstall.checksumFile)")
        guard let checksums = try? String(contentsOf: file, encoding: .utf8) else { throw SocketClientError(refusal) }
        return (identity.version, checksums)
    }

    private func probeArchitecture(_ argv: [String]) throws -> String {
        let probe = try spawn { try effects.capture(argv) }
        guard probe.outcome == .exited(0) else { throw SocketClientError("ssh exited with \(probe.outcome) asking the host for its architecture") }
        do {
            return try ServerInstall.architecture(probeOutput: probe.output)
        } catch ServerInstall.Failure.unsupportedArchitecture(let name) {
            throw SocketClientError("unsupported host architecture '\(name)'; agterm-server is built for "
                + ServerInstall.architectures.joined(separator: " and "))
        }
    }

    private func spawn<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as ForegroundSpawn.Failure {
            throw SocketClientError("could not start ssh: \(failure.operation) failed with \(String(cString: strerror(failure.errno)))")
        }
    }

    private func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// ReleaseDownload fetches one release asset into a private file, stopping at the size limit while it writes
/// and refusing a non-2xx answer or a redirect off HTTPS.
final class ReleaseDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Refused: Error, CustomStringConvertible {
        let description: String
    }

    private let handle: FileHandle
    private let limit: Int
    private let done = DispatchSemaphore(value: 0)
    // written on the session's delegate queue, read after `done` is signaled
    private var written = 0
    private(set) var failure: Error?

    init(handle: FileHandle, limit: Int) {
        self.handle = handle
        self.limit = limit
    }

    static func fetch(_ url: URL, to file: URL, limit: Int) throws {
        guard url.scheme == "https" else { throw Refused(description: "not an https URL") }
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Refused(description: "could not create \(file.path)")
        }
        let download = ReleaseDownload(handle: try FileHandle(forWritingTo: file), limit: limit)
        defer { try? download.handle.close() }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: download, delegateQueue: queue)
        session.dataTask(with: url).resume()
        download.done.wait()
        session.finishTasksAndInvalidate()
        if let failure = download.failure { throw failure }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else {
            failure = Refused(description: "redirected off https to \(request.url?.absoluteString ?? "nothing")")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            failure = Refused(description: "the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        written += data.count
        guard written <= limit else {
            failure = Refused(description: "larger than \(limit) bytes")
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil, let error { failure = error }
        done.signal()
    }
}
#endif
