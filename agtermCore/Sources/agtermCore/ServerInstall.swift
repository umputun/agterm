import Foundation

/// ServerInstall holds the host-free rules of `agtermctl server install`: which release asset a host needs, how the app's bundled
/// checksum file vouches for it, and the ssh commands that probe the host, unpack the tarball and run its installer.
/// `scripts/install-server.sh` sends the same two remote strings from a source tree.
public enum ServerInstall {
    public enum Failure: Error, Equatable {
        /// unsupportedArchitecture means `uname -m` on the host named something no tarball is built for.
        case unsupportedArchitecture(String)
        /// checksumMissing means the checksum file has no line for the asset.
        case checksumMissing(asset: String)
        /// checksumMalformed means the checksum file has a line that is not `<64 hex>  <name>`.
        case checksumMalformed(line: Int)
        /// checksumDuplicate means the checksum file names the asset more than once.
        case checksumDuplicate(asset: String)
    }

    public static let architectures = ["aarch64", "x86_64"]
    /// checksumFile is the checksum file's name in the app's `Contents/Resources`, written there by `scripts/release.sh`.
    public static let checksumFile = "agterm-server.sha256"
    /// downloadLimit is the largest download accepted, in bytes.
    public static let downloadLimit = 256 << 20

    public static func assetName(version: String, architecture: String) -> String {
        "agterm-server-\(version)-linux-\(architecture).tar.gz"
    }

    public static func downloadURL(version: String, architecture: String) -> URL {
        URL(string: "https://github.com/umputun/agterm/releases/download/v\(version)/"
            + assetName(version: version, architecture: architecture))!
    }

    /// architecture reads the probe's `uname -m` output.
    public static func architecture(probeOutput: Data) throws -> String {
        let name = String(decoding: probeOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard architectures.contains(name) else { throw Failure.unsupportedArchitecture(name) }
        return name
    }

    /// checksum returns the lowercase sha256 the file records for `asset`. Every line must be well formed, so a
    /// damaged file is refused even when the asset's own line looks fine.
    public static func checksum(for asset: String, in text: String) throws -> String {
        var found: String?
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[1].hasPrefix(" "), isDigest(fields[0]) else {
                throw Failure.checksumMalformed(line: index + 1)
            }
            guard fields[1].dropFirst() == asset else { continue }
            guard found == nil else { throw Failure.checksumDuplicate(asset: asset) }
            found = fields[0].lowercased()
        }
        guard let found else { throw Failure.checksumMissing(asset: asset) }
        return found
    }

    private static func isDigest(_ value: Substring) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    /// unpackScript is the host side of the unpack, with the tarball on stdin: unpacked beside the live directory and swapped in by
    /// rename, so a running server keeps its open binary. One line, because the account's login shell parses the
    /// quoted command first and tcsh rejects a quoted newline.
    static let unpackScript = #"set -e; lib="$HOME/.local/lib/agterm-server"; mkdir -p "$HOME/.local/lib"; "#
        + #"rm -rf "$lib.new" "$lib.old"; mkdir "$lib.new"; tar -xzf - -C "$lib.new"; "#
        + #"if [ -e "$lib" ]; then mv "$lib" "$lib.old"; fi; mv "$lib.new" "$lib"; rm -rf "$lib.old""#

    /// installerCommand runs the tarball's installer from where the unpack put it.
    static let installerCommand = #"bash "$HOME/.local/lib/agterm-server/install.sh""#

    public static func probeCommand(_ connection: TerminfoInstall.Connection, ssh: String = "ssh") throws -> [String] {
        try TerminfoInstall.sshCommand(connection, ssh: ssh) + ["uname -m"]
    }

    public static func unpackCommand(_ connection: TerminfoInstall.Connection, ssh: String = "ssh") throws -> [String] {
        try TerminfoInstall.sshCommand(connection, ssh: ssh) + ["sh -c '\(unpackScript)'"]
    }

    public static func installerCommand(_ connection: TerminfoInstall.Connection, ssh: String = "ssh") throws -> [String] {
        try TerminfoInstall.sshCommand(connection, ssh: ssh) + [installerCommand]
    }

    /// exitCode maps the installer's outcome to the command's: 0 installed, 3 installed with the agent hooks
    /// incomplete, 1 for anything else.
    public static func exitCode(_ outcome: ForegroundSpawn.Outcome) -> Int32 {
        switch outcome {
        case .exited(0): 0
        case .exited(3): 3
        default: 1
        }
    }
}
