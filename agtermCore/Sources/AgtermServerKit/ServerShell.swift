import Foundation
import agtermCore

/// ServerShell is the login shell agterm-server starts its panes with and how ghostty's shell integration is
/// loaded into it: zsh and fish as the Mac's Live panes load it, bash through its POSIX-mode `ENV`.
public enum ServerShell: Equatable, Sendable {
    case zsh(String)
    case fish(String)
    case bash(String)

    /// named is the shell at `path`, nil for one the server does not run.
    public static func named(_ path: String) -> ServerShell? {
        switch (path as NSString).lastPathComponent {
        case "zsh": .zsh(path)
        case "fish": .fish(path)
        case "bash": .bash(path)
        default: nil
        }
    }

    public static func refusal(_ path: String) -> String {
        "agterm-server panes run zsh, fish or bash; \(path) is not supported"
    }

    public var path: String {
        switch self {
        case .zsh(let path), .fish(let path), .bash(let path): path
        }
    }

    /// launch is the program and environment for a pane. With no `command` the pane is the login shell, which
    /// zmx starts from `SHELL` for zsh and fish; bash needs its flags. A `command` runs through the login shell
    /// once and the pane ends with it, as `session.new --command` does on the Mac.
    public func launch(integration: String, environment base: [String: String],
                       command: String?) -> (argv: [String], environment: [String: String]) {
        var environment = base
        environment["SHELL"] = path
        switch self {
        case .zsh:
            if let user = base["ZDOTDIR"] { environment["GHOSTTY_ZSH_ZDOTDIR"] = user }
            environment["ZDOTDIR"] = (integration as NSString).appendingPathComponent("zsh")
            return (command.map { [path, "-lic", ZmxReplayScript.renderEnding(commandLine: $0)] } ?? [], environment)
        case .fish:
            environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integration
            let inherited = base["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share"
            environment["XDG_DATA_DIRS"] = integration + ":" + inherited
            return (command.map { [path, "-lic", ZmxReplayScript.renderFishEnding(commandLine: $0)] } ?? [], environment)
        case .bash:
            // ghostty.bash leaves POSIX mode, restores the user's ENV and sources the login files itself
            if let user = base["ENV"] { environment["GHOSTTY_BASH_ENV"] = user }
            environment["ENV"] = (integration as NSString).appendingPathComponent("bash/ghostty.bash")
            environment["GHOSTTY_BASH_INJECT"] = "1"
            if base["HISTFILE"] == nil, let home = base["HOME"] {
                environment["HISTFILE"] = (home as NSString).appendingPathComponent(".bash_history")
                environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
            let script = command.map { ["-lic", ZmxReplayScript.renderEnding(commandLine: $0)] } ?? ["-l"]
            return ([path, "--posix"] + script, environment)
        }
    }
}
