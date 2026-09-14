import ArgumentParser
import Foundation
import agtermCore

// MARK: - terminfo

/// Local-only: it never touches the control socket, so there is no protocol command, no `--json` and no
/// running agterm needed. `control-api.md` records the exemption.
struct Terminfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The terminal's terminfo entry on other hosts.",
        subcommands: [Install.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the xterm-ghostty terminfo entry on a remote host over ssh.",
            discussion: """
            agterm's shells run with TERM=xterm-ghostty. A host without that entry makes less, vim and \
            other full-screen programs warn that the terminal is not fully functional. This dumps the \
            bundled entry with infocmp and compiles it into the remote account's ~/.terminfo with tic, \
            over one ssh connection. Run it once per host and account; nothing is cached and ssh itself \
            is untouched.

            The connection is interactive: a password or host-key prompt is answered on this terminal. \
            Other connection settings belong in ~/.ssh/config under a host alias, which ssh reads as \
            usual; the settings that decide how the command itself runs (no pty, stdin kept, a plain \
            session, no fork, no RemoteCommand) are set by the installer and win over the config. The \
            remote needs tic, which comes with ncurses, and says so when it is missing. Exits with \
            ssh's status.
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

        func validate() throws {
            do {
                _ = try TerminfoInstall.installCommand(connection)
            } catch TerminfoInstall.Failure.invalidDestination {
                throw ValidationError("destination must be a host, user@host or an ssh alias, not '\(destination)'")
            }
        }

        var connection: TerminfoInstall.Connection {
            TerminfoInstall.Connection(destination: destination, port: port, identities: identity, jump: jump,
                                       config: config)
        }

        func run() throws {
            let outcome: TerminfoInstall.Outcome
            do {
                outcome = try TerminfoInstall.run(connection, clientPath: Version.clientPath(),
                                                  environment: ProcessInfo.processInfo.environment)
            } catch let TerminfoInstall.Failure.terminfoNotFound(searched) {
                // a runtime failure, not a usage one: no usage block under it
                throw SocketClientError("no \(TerminfoInstall.entry) terminfo entry next to this agtermctl; looked in "
                    + searched.joined(separator: ", "))
            } catch let TerminfoInstall.Failure.dumpFailed(status, stderr) {
                throw SocketClientError("infocmp exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch let TerminfoInstall.Failure.spawnFailed(operation, errno) {
                throw SocketClientError("could not start ssh: \(operation) failed with \(String(cString: strerror(errno)))")
            }
            switch outcome {
            case .exited(0):
                print("installed \(TerminfoInstall.entry) on \(destination)")
            case .exited(let status):
                FileHandle.standardError.write(Data("ssh exited \(status); \(TerminfoInstall.entry) was not installed\n".utf8))
                throw ExitCode(status)
            case .signaled(let signal):
                FileHandle.standardError.write(Data("ssh was killed by signal \(signal); \(TerminfoInstall.entry) was not installed\n".utf8))
                throw ExitCode(128 + signal)
            }
        }
    }
}
