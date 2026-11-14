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

    /// Program is what a pane runs.
    public enum Program: Equatable, Sendable {
        /// loginShell is the integrated login shell.
        case loginShell
        /// command runs a line once through the login shell and the pane ends with it, as `session.new --command`
        /// does on the Mac; `wait` holds the pane for a key after it, whatever way the line ended.
        case command(String, wait: Bool)
        /// returning runs a line through the login shell, then the pane becomes the integrated login shell, as
        /// `session.restart --command` does on the Mac.
        case returning(String)
        /// replay runs a program again, then the pane becomes the integrated login shell.
        case replay([String])

        /// creation is what a creation request's optional command and wait flag run.
        static func creation(_ command: String?, wait: Bool?) -> Program {
            command.map { .command($0, wait: wait == true) } ?? .loginShell
        }
    }

    /// bashExports are the variables ghostty.bash consumes when it loads, which a replay exports again before it
    /// execs the login shell.
    static let bashExports = ["ENV", "GHOSTTY_BASH_INJECT", "GHOSTTY_BASH_ENV", "HISTFILE", "GHOSTTY_BASH_UNEXPORT_HISTFILE"]

    private func rearmExports(_ environment: [String: String]) -> [(name: String, value: String)] {
        Self.bashExports.compactMap { name in environment[name].map { (name, $0) } }
    }

    /// launch is the argv and environment for a pane. zmx starts the zsh and fish login shell from `SHELL`; bash
    /// needs its flags.
    public func launch(integration: String, environment base: [String: String],
                       program: Program) -> (argv: [String], environment: [String: String]) {
        var environment = base
        environment["SHELL"] = path
        switch self {
        case .zsh:
            if let user = base["ZDOTDIR"] { environment["GHOSTTY_ZSH_ZDOTDIR"] = user }
            let directory = (integration as NSString).appendingPathComponent("zsh")
            environment["ZDOTDIR"] = directory
            let script: String? = switch program {
            case .loginShell: nil
            case .command(let line, wait: true): ZmxReplayScript.renderHolding(commandLine: line)
            case .command(let line, wait: false): ZmxReplayScript.renderEnding(commandLine: line)
            case .returning(let line):
                ZmxReplayScript.render(commandLine: line, integrationDirectory: directory, inheritedZdotdir: base["ZDOTDIR"],
                                       shell: path)
            case .replay(let argv):
                ZmxReplayScript.render(argv: argv, integrationDirectory: directory, inheritedZdotdir: base["ZDOTDIR"],
                                       shell: path)
            }
            return (script.map { [path, "-lic", $0] } ?? [], environment)
        case .fish:
            environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integration
            let inherited = base["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share"
            environment["XDG_DATA_DIRS"] = integration + ":" + inherited
            let script: String? = switch program {
            case .loginShell: nil
            case .command(let line, wait: true): ZmxReplayScript.renderFishHolding(commandLine: line, shell: path)
            case .command(let line, wait: false): ZmxReplayScript.renderFishEnding(commandLine: line)
            case .returning(let line): ZmxReplayScript.renderFish(commandLine: line, integrationRoot: integration, shell: path)
            case .replay(let argv): ZmxReplayScript.renderFish(argv: argv, integrationRoot: integration, shell: path)
            }
            return (script.map { [path, "-lic", $0] } ?? [], environment)
        case .bash:
            // ghostty.bash leaves POSIX mode, restores the user's ENV and sources the login files itself
            if let user = base["ENV"] { environment["GHOSTTY_BASH_ENV"] = user }
            environment["ENV"] = (integration as NSString).appendingPathComponent("bash/ghostty.bash")
            environment["GHOSTTY_BASH_INJECT"] = "1"
            if base["HISTFILE"] == nil, let home = base["HOME"] {
                environment["HISTFILE"] = (home as NSString).appendingPathComponent(".bash_history")
                environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
            let script: String? = switch program {
            case .loginShell: nil
            case .command(let line, wait: true): ZmxReplayScript.renderBashHolding(commandLine: line)
            case .command(let line, wait: false): ZmxReplayScript.renderEnding(commandLine: line)
            case .returning(let line): ZmxReplayScript.renderBash(commandLine: line, exports: rearmExports(environment), shell: path)
            case .replay(let argv): ZmxReplayScript.renderBash(argv: argv, exports: rearmExports(environment), shell: path)
            }
            return ([path, "--posix"] + (script.map { ["-lic", $0] } ?? ["-l"]), environment)
        }
    }
}
