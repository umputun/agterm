import ArgumentParser
import Foundation
import agtermCore

// MARK: - zmx

struct Zmx: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect and manage the daemons behind live sessions.",
        discussion: """
        Live sessions keep each primary and split pane's process alive in a zmx daemon, so closing agterm \
        ends the attach client while the process keeps running. These commands show which daemons exist, \
        who owns them, and which are left over.

        Every one needs a running agterm: only the app can join its live windows, its pending closes and \
        its persisted snapshots against what zmx reports. With agterm stopped there is nothing to ask.
        """,
        subcommands: [List.self, Prune.self, Kill.self, Tree.self, Attach.self]
    )

    struct Attach: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Attach to a session on another Mac, as a session here.",
            discussion: """
            Takes a host and the id of one of the sessions `zmx tree` listed, and opens it in this window \
            marked as remote. A remote session with a split arrives with the same split.

            The remote is resolved again before anything is created, so a session that has gone since the \
            list was taken fails rather than handing back a fresh shell wearing its name.

            Closing it here ends only this side's connection: the far-side processes keep running, and \
            nothing this command does can kill them. The session is not restored after a relaunch.
            """)
        @Argument(help: "The host, as ssh would take it.")
        var host: String
        @Argument(help: "The remote session's id, as `zmx tree` prints it.")
        var session: String
        @OptionGroup var options: BasicOptions

        /// It creates a local session, so it echoes that session's id like every other create command.
        var echoesResultID: Bool { true }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .zmxAttach, target: session, args: ControlArgs(host: host))
        }
    }

    struct Tree: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the sessions that can be attached to, here or on another Mac.",
            discussion: """
            With a HOST, runs over ssh against a machine that is also running agterm and reports what it \
            offers, across every one of its open windows. Feed the result to a picker and hand what the \
            user chooses to `zmx attach`.

            With no HOST, reports this app's own attachable sessions in the same shape — which is exactly \
            the form the remote call runs on the far side, so it is also how to see what another machine \
            would answer without sshing anywhere.

            Only a session whose every pane has a live daemon is listed. One whose daemon has gone is \
            omitted rather than offered, because attaching to a name that no longer exists would create a \
            fresh shell wearing it. An empty list is a successful answer: it does not distinguish a store \
            that is not running in live mode, which `zmx list` reports.

            The connection is non-interactive: ssh runs with BatchMode, so key-based auth must already \
            work for this host and a password or host-key prompt is a failure rather than a question.
            """)
        @Argument(help: "The host, as ssh would take it. Omit for this app's own sessions.")
        var host: String?
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .zmxTree, args: ControlArgs(host: host))
        }
    }

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "List every daemon and the pane that claims it.",
            discussion: """
            One row per daemon and per pane expecting one, so a leaked daemon and a pane whose daemon has \
            vanished are both visible. The header reports the restore mode this launch is running.

            State reads: claimed (a pane owns it), orphan (nothing does), pendingClose (its session is \
            inside its undo window), foreign (a zmx session that is not agterm's), unknown (the pane \
            inventory was incomplete, so no row can be called an orphan), conflicted (two panes claim it).

            A closed window's panes are claimed with zero clients. That is the normal resting state after \
            you close a window, not a leak.
            """)
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .zmxList) }
    }

    struct Prune: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Kill the daemons no pane claims and nothing is attached to.",
            discussion: """
            Acts only on rows `zmx list` shows as orphan with no clients, so you can see what is eligible \
            before running it. It refuses outright when the pane inventory is incomplete or two panes \
            claim one daemon, since neither answer can be acted on safely.

            The check is not atomic. zmx has no kill-if-detached, so this re-lists immediately before it \
            kills and drops anything that gained a client in between; a client attaching from outside \
            agterm inside that last gap can still be terminated.

            It reports each daemon separately. A "cleaned up a stale socket" line is not a kill: zmx \
            unlinked a socket it could not reach, and that daemon may still be running.
            """)
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .zmxPrune) }
    }

    struct Kill: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Destroy one pane's daemon and the process running in it.",
            discussion: """
            This kills a backend process, not a model object. It reaches a pane no window is currently \
            showing, and it takes down every client attached to that daemon, so there is no sensible \
            default for who is affected: the target, the pane and --force are all required.

            What happens next depends on the pane. Killing a shown split closes that split; killing a \
            primary promotes its split survivor, or closes the session when there is none. A pane whose \
            window is closed simply comes back as a fresh shell on its next attach. None of these gets \
            the three-second undo, and Reopen Closed Item brings the session back with a fresh shell \
            rather than the process that was running.

            Killing the daemon of the pane you are typing in can kill this agtermctl before it reads the \
            reply, the same way "session close" on your own session can.

            It refuses a daemon that is already gone, one zmx could not read (forcing that can unlink a \
            live daemon's socket and leave it running unreachable), and a session inside its undo window.
            """)
        @Option(name: .long, help: "Which pane's daemon: left/primary/top or right/split/bottom.")
        var pane: String

        @Flag(name: .long, help: "Required. Confirms destroying the process running in that pane.")
        var force = false

        /// Required and never defaulted, unlike every other command's `--target`: the whole contract here
        /// is that nothing about this destruction falls back to whatever is in front of you.
        @Option(name: .long, help: "Session id or unique prefix. Required; 'active' is not accepted.")
        var target: String

        /// Its own option rather than `ClientOptions`, whose help promises `active` and a frontmost
        /// default. Both are wrong here: omitting it searches EVERY window's claims, including closed and
        /// unindexed ones the frontmost window knows nothing about.
        @Option(name: .long, help: "Window id or unique prefix to disambiguate. Omit to search every window; 'active' is not accepted.")
        var window: String?

        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard ZmxPaneRole(controlName: pane) != nil else {
                throw ValidationError("--pane must be left/primary/top or right/split/bottom")
            }
            guard force else { throw ValidationError("--force is required to destroy a running process") }
            guard target != "active" else {
                throw ValidationError("--target must name a session; 'active' is not accepted here")
            }
            guard window != "active" else {
                throw ValidationError("--window must name a window; 'active' is not accepted here")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .zmxKill, target: target,
                           args: ControlArgs(force: true, window: window, pane: pane))
        }
    }
}
