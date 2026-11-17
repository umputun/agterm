import ArgumentParser
import Foundation
import agtermCore

// MARK: - paste

/// Paste is local-only: it never touches the control socket, so there is no protocol command and no `--json`.
/// `control-api.md` records the exemption.
struct Paste: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Files pasted into a pane whose program runs on this host.",
        subcommands: [Receive.self]
    )

    struct Receive: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stage files agterm sends for a paste or drop. Internal; agterm runs it over ssh.",
            discussion: """
            When files, a folder or a clipboard image are pasted or dropped into a pane whose program runs on \
            this host, agterm on the Mac showing the pane runs this over ssh and sends them on standard input. \
            They are written under agterm/paste in the user's cache folder (~/Library/Caches on macOS, \
            ~/.cache on Linux), readable only by the user; pastes older than 24 hours are removed on the next \
            paste. The staged paths are printed as JSON. It is not meant to be run by hand.
            """)

        func run() throws {
            guard isatty(STDIN_FILENO) == 0 else { throw ValidationError("agterm sends the files on standard input") }
            let reply = Self.receive(from: .standardInput, staging: PasteStaging())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(reply), as: UTF8.self))
            if reply.paths == nil { throw ExitCode.failure }
        }

        static func receive(from input: FileHandle, staging: PasteStaging) -> PasteStaging.Reply {
            do {
                return PasteStaging.Reply(paths: try staging.receive(from: input))
            } catch {
                return PasteStaging.Reply(error: String(describing: error))
            }
        }
    }
}
