import ArgumentParser
import Foundation
import agtermCore

// MARK: - workspace

struct Workspace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Workspace commands.",
        subcommands: [New.self, Rename.self, Delete.self, Select.self, Move.self, Focus.self, Root.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a workspace.")
        @Argument(help: "Workspace name (defaults to the auto-generated name).") var name: String?
        @OptionGroup var options: ClientOptions
        var echoesResultID: Bool { true }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceNew, args: options.withWindow(ControlArgs(name: name)))
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

    struct Focus: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Focus the sidebar on a single workspace (on|off|toggle).")
        @Argument(help: "Mode: on (focus), off (unfocus), or toggle (default).") var mode: String = "toggle"
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard ["on", "off", "toggle"].contains(mode) else {
                throw ValidationError("mode must be on, off, or toggle")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceFocus, target: target.target, args: options.withWindow(ControlArgs(mode: mode)))
        }
    }

    struct Root: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a workspace's root directory (new sessions open there), or clear it.")
        @Argument(help: "A directory path, or `clear` to unset the root.") var dir: String?
        @Flag(help: "Clear the workspace's root directory.") var clear = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            let hasDir = !(dir?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            guard clear || hasDir else {
                throw ValidationError("provide a directory path, or --clear")
            }
        }

        func makeRequest() throws -> ControlRequest {
            var path: String?
            if !clear, let raw = dir, raw != "clear" {
                // absolutize a relative/~ path — the app resolves it in ITS own cwd, not the CLI's.
                let expanded = (raw as NSString).expandingTildeInPath
                let base = expanded.hasPrefix("/") ? expanded
                    : FileManager.default.currentDirectoryPath + "/" + expanded
                path = URL(fileURLWithPath: base).standardizedFileURL.path
            }
            return ControlRequest(cmd: .workspaceRoot, target: target.target, args: options.withWindow(ControlArgs(path: path)))
        }
    }
}
