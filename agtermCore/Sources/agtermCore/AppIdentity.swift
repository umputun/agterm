import Foundation

/// Which agterm is serving this control socket. Derived ONCE by the app from its own bundle and projected
/// unchanged into both `tree` and `version`, so the two can never disagree. `version` is the comparable
/// number a recipe checks its minimum against; `commit` is diagnostics only and never part of that
/// comparison.
public struct AppIdentity: Codable, Sendable, Equatable {
    public let version: String
    /// The build's git commit, omitted for a build that recorded none.
    public let commit: String?

    public init(version: String, commit: String? = nil) {
        self.version = version
        self.commit = commit
    }

    /// Build from raw bundle values. `commit` is dropped when the build recorded nothing usable — absent,
    /// empty, or the literal `unknown` that `build.sh`/`release.sh` emit when git cannot answer — so no
    /// caller renders `0.24.0 (unknown)`.
    public init(version: String, recordedCommit: String?) {
        self.version = version
        switch recordedCommit {
        case nil, "", "unknown": self.commit = nil
        default: self.commit = recordedCommit
        }
    }

    /// The build metadata of the bundle on disk at `bundleURL`, which differs from the running identity
    /// once the bundle is replaced underneath a running app. Nil when the plist cannot be read or names
    /// no version. Parsed from the file on every call: `Bundle` caches its info dictionary.
    public static func installed(bundleURL: URL) -> AppIdentity? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }
        return AppIdentity(version: version, recordedCommit: info["GitCommit"] as? String)
    }
}
