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
}
