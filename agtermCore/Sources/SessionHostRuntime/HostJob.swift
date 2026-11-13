import Darwin
import Foundation

/// HostJob is a session host started as a launchd job in the user's GUI domain, which gives the host and
/// its daemons a coalition of their own instead of the one of the agterm that spawned it (#985).
struct HostJob: Equatable {
    enum Outcome: Equatable {
        case succeeded
        case failed(String)
        /// launchctl outlived its deadline and was killed, so the job may or may not be loaded.
        case uncertain
    }

    let label: String
    let arguments: [String]
    let umask: mode_t

    static var supported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    /// labelPrefix starts the label of every job for one endpoint; each attempt adds a nonce so a new job
    /// never replaces or removes a host another attempt started.
    static func labelPrefix(bundleID: String, key: String) -> String {
        "\(bundleID).session-host.\(key)."
    }

    init(bundleID: String, key: String, executable: String, socketDirectory: String, umask: mode_t,
         nonce: String = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))) {
        label = Self.labelPrefix(bundleID: bundleID, key: key) + nonce
        arguments = [executable, "host", socketDirectory, key, label]
        self.umask = umask
    }

    /// plist sets no environment: the host's own only feeds its `zmx list`, and each pane's travels in
    /// its request.
    func plist() throws -> Data {
        let job: [String: Any] = ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true, "KeepAlive": false,
                                  "ProcessType": "Interactive", "AbandonProcessGroup": true, "Umask": Int(umask)]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }

    /// bootstrap loads the job from a private plist in `directory`, removed once launchctl returns: launchd
    /// keeps the definition it read.
    func bootstrap(directory: String, deadline: TimeInterval) -> Outcome {
        let path = URL(fileURLWithPath: directory).appendingPathComponent("\(label).plist").path
        do {
            let data = try plist()
            let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            try hostCheck(fd)
            defer { close(fd) }
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == data.count else { throw HostFailure.system(errno) }
        } catch {
            unlink(path)
            return .failed("plist: \(error)")
        }
        defer { unlink(path) }
        return Self.launchctl(["bootstrap", "gui/\(getuid())", path], deadline: deadline)
    }

    /// bootout removes the job named `label`, ending its process if it still runs.
    static func bootout(label: String, deadline: TimeInterval) -> Outcome {
        launchctl(["bootout", "gui/\(getuid())/\(label)"], deadline: deadline)
    }

    /// launchctl's exit status is the error number it prints, so the status alone carries the diagnostic.
    private static func launchctl(_ arguments: [String], deadline: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failed("launchctl: \(error)") }
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return .uncertain
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .failed("launchctl \(arguments[0]) status \(process.terminationStatus)")
        }
        return .succeeded
    }
}
