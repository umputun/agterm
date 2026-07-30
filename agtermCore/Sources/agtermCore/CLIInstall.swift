import Foundation

/// Pure, host-free helpers for installing the bundled `agtermctl` CLI into the user's PATH — only the
/// testable string/path logic. The app side does the filesystem work: a symlink, with an `osascript` admin
/// fallback when the target dir isn't user-writable.
public enum CLIInstall {
    /// The CLI tool's executable name.
    public static let toolName = "agtermctl"

    /// The PATH directory the tool is installed into. `/usr/local/bin` is the first entry in macOS's
    /// default `/etc/paths`, so it's on every user's PATH out of the box (unlike `~/.local/bin`).
    public static let installDirectory = "/usr/local/bin"

    /// The full symlink path an install creates.
    public static var installPath: String { installDirectory + "/" + toolName }

    /// The shell command creating the symlink with elevated privileges, run via `osascript … with
    /// administrator privileges` when `installDirectory` isn't user-writable. Creates the directory first
    /// (a clean Apple Silicon Mac may lack it) and overwrites any existing link.
    public static func privilegedInstallCommand(source: String) -> String {
        "mkdir -p \(shellQuote(installDirectory)) && ln -sf \(shellQuote(source)) \(shellQuote(installPath))"
    }

    /// Single-quote a string for safe embedding in a `/bin/sh` command.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
