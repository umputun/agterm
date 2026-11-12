import Foundation

extension Session {
    /// The working directory for a given pane role, each pane's own, falling back to the primary's.
    public func cwd(for pane: CommandContext.Pane) -> String {
        switch pane {
        case .right:
            return splitCwd ?? initialSplitCwd ?? effectiveCwd
        case .scratch:
            return scratchCwd ?? effectiveCwd
        case .left:
            return effectiveCwd
        }
    }

    /// The host a pane's shell runs on: `remoteHost`, except for a scratch that runs on this Mac, which an
    /// attached session's is. A remote window's scratch attaches the server's shell, so it keeps the host.
    public func remoteHost(for pane: CommandContext.Pane) -> String? {
        pane == .scratch && catalogScratch == nil ? nil : remoteHost
    }

    /// Where a LOCAL process for this session starts, given the pane path it would inherit: that path on a
    /// local session; on a remote one, only when it exists here as a directory, else `homeDirectory`. The
    /// reported path itself stays what `cwd(for:)` and `AGT_SESSION_PWD` carry.
    public func localWorkingDirectory(reported path: String, homeDirectory: String) -> String {
        guard remoteHost != nil else { return path }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? path : homeDirectory
    }
}
