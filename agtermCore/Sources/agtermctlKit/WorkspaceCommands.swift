import ArgumentParser
import agtermCore

// MARK: - workspace

struct Workspace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Workspace commands.",
        subcommands: [New.self, Rename.self, Delete.self, Select.self, Move.self, Focus.self, Filter.self,
                      Collapse.self, Expand.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a workspace.")
        @Argument(help: "Workspace name (defaults to the auto-generated name).") var name: String?
        @Flag(name: .long, help: "Create the workspace collapsed in the sidebar.") var collapsed = false
        @OptionGroup var options: ClientOptions
        var echoesResultID: Bool { true }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceNew, args: options.withWindow(ControlArgs(name: name, collapsed: collapsed ? true : nil)))
        }
    }

    struct Rename: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a workspace.")
        @Argument(help: "New workspace name.") var name: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceRename, target: target.target, args: options.withWindow(ControlArgs(name: name)))
        }
    }

    struct Delete: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a workspace.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceDelete, target: target.target, args: options.withWindow())
        }
    }

    struct Select: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Select a workspace.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceSelect, target: target.target, args: options.withWindow())
        }
    }

    struct Move: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Reorder a workspace among its siblings.")
        @Option(name: .long, help: "Direction: up, down, top, or bottom.") var to: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceMove, target: target.target, args: options.withWindow(ControlArgs(to: to)))
        }
    }

    /// `agtermctl workspace focus [on|off|toggle|add] [--target W]` — marks or unmarks ONE workspace in
    /// the sidebar's focus set. `add` only marks; applying the set is `workspace filter on`. The accepted
    /// list, the help text, and the local rejection message all derive from `WorkspaceFocusMode.allCases`,
    /// so the CLI cannot drift from the dispatcher's parse.
    struct Focus: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mark a workspace in the sidebar focus set (\(WorkspaceFocusMode.validNamesList))."
        )
        @Argument(help: """
            Mode: on (mark it alone), off (unmark it), toggle (replace-toggle, the default), or add \
            (mark it alongside the others, leaving the filter flag alone).
            """)
        var mode: String = WorkspaceFocusMode.toggle.rawValue
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard WorkspaceFocusMode(rawValue: mode) != nil else {
                throw ValidationError("mode must be one of: \(WorkspaceFocusMode.validNamesPhrase)")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceFocus, target: target.target, args: options.withWindow(ControlArgs(mode: mode)))
        }
    }

    /// `agtermctl workspace filter [on|off|toggle] [--window W]` — turns the sidebar's workspace focus
    /// filter on or off for a WHOLE window, leaving the marked set intact. It deliberately carries NO
    /// `--target`: it flips the window's filter rather than acting on one workspace, so its shape is
    /// `sidebar expand`/`sidebar collapse` (`ClientOptions` only), not the `workspace.*` target commands.
    struct Filter: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn the sidebar workspace focus filter on or off (on|off|toggle)."
        )
        @Argument(help: "Mode: on, off, or toggle (default).") var mode: String = "toggle"
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard ["on", "off", "toggle"].contains(mode) else {
                throw ValidationError("mode must be on, off, or toggle")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceFilter, args: options.withWindow(ControlArgs(mode: mode)))
        }
    }

    struct Collapse: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Collapse a workspace in the sidebar tree.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceCollapse, target: target.target, args: options.withWindow())
        }
    }

    struct Expand: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Expand a workspace in the sidebar tree.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceExpand, target: target.target, args: options.withWindow())
        }
    }
}
