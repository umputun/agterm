import ArgumentParser
import agtermCore

extension Session {
    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a session.")
        @Option(name: .long, help: "Working directory (defaults to $HOME).") var cwd: String?
        @Option(name: .long, help: "Target workspace by id/prefix/active (defaults to the current one). Mutually exclusive with --workspace-name.") var workspace: String?
        @Option(name: .long, help: "Target workspace by name; errors if not found unless --create-workspace. Mutually exclusive with --workspace.") var workspaceName: String?
        @Flag(name: .long, help: "With --workspace-name, create the workspace when it does not exist (reuse it otherwise).") var createWorkspace = false
        @Option(name: .long, help: "Run this command as the session's process instead of the login shell (no echoed command line; the session closes when it exits).") var command: String?
        @Flag(name: .long, help: "With --command, hold the session open after the command exits (press any key to close) instead of closing immediately.") var wait = false
        @Option(name: .long, help: "Initial session name (defaults to the auto basename).") var name: String?
        @Option(name: .long, help: "Place the new session right AFTER this anchor session (id/prefix/active); the anchor carries its own workspace, replacing --workspace.") var after: String?
        @Option(name: .long, help: "Place the new session right BEFORE this anchor session (id/prefix/active); mirror of --after.") var before: String?
        @Flag(name: .long, help: "Create the session in the background without selecting or focusing it (leaves the current selection untouched).") var noSelect = false
        @Option(name: .long, help: "Create a companion of this session (id/prefix/active), placed under it in the sidebar; a companion target means its parent.") var parent: String?
        @Option(name: .long, help: ArgumentHelp("Create the session on this host (an ssh destination running agterm or agterm-server) and attach it "
                    + "here, in the window's current workspace; --workspace-name names the workspace there, default the current one's name."))
        var remote: String?
        @Option(name: .long, help: "With --remote on a Mac: the window there to create in, an id or unique prefix; needed when it has several open.") var originWindow: String?
        @OptionGroup var tint: TintCreateOptions
        @OptionGroup var options: ClientOptions
        @OptionGroup var operation: OperationOptions
        var echoesResultID: Bool { true }

        func validate() throws {
            if originWindow != nil, remote == nil { throw ValidationError("--origin-window requires --remote") }
            if remote != nil {
                if parent != nil || workspace != nil || createWorkspace || after != nil || before != nil {
                    throw ValidationError("--remote takes no --parent, --workspace, --create-workspace, --after or --before")
                }
                if wait || name != nil || noSelect || tint.tint != nil || tint.tintOn != nil || operation.opID != nil {
                    throw ValidationError("--remote takes no --wait, --name, --no-select, --tint or --op-id")
                }
            }
            if parent != nil, workspace != nil || workspaceName != nil || createWorkspace || after != nil || before != nil {
                throw ValidationError("--parent takes no --workspace, --workspace-name, --create-workspace, --after or --before")
            }
            if after != nil, before != nil {
                throw ValidationError("use either --after or --before, not both")
            }
            // the anchor sid already names the workspace, so placement can't also address one.
            if after != nil || before != nil, workspace != nil || workspaceName != nil {
                throw ValidationError("session.new takes --after/--before or a workspace, not both")
            }
            if workspace != nil, workspaceName != nil {
                throw ValidationError("use either --workspace or --workspace-name, not both")
            }
            if createWorkspace, workspaceName == nil {
                throw ValidationError("--create-workspace requires --workspace-name")
            }
            if wait, command == nil {
                throw ValidationError("--wait requires --command")
            }
        }

        func run() throws {
            if remote != nil {
                return try runCompanionRequest(makeRequest(), options: options, echoID: true,
                                               tooOld: "the running app is too old for remote sessions")
            }
            guard parent != nil else { return try defaultRun() }
            try runCompanionRequest(makeRequest(), options: options, echoID: true)
        }

        func makeRequest() throws -> ControlRequest {
            // its own wire command: an app predating it would drop `host` and create a local session
            if let remote {
                var args = ControlArgs(cwd: cwd, workspaceName: workspaceName, host: remote, command: command)
                args.originWindow = originWindow
                return ControlRequest(cmd: .sessionRemoteNew, args: options.withWindow(args))
            }
            if let parent {
                return operation.stamp(ControlRequest(cmd: .sessionCompanionNew, target: parent,
                                                      args: options.withWindow(tint.apply(to:
                    ControlArgs(name: name, cwd: cwd, noSelect: noSelect ? true : nil, command: command,
                                wait: wait ? true : nil)))))
            }
            return operation.stamp(ControlRequest(cmd: .sessionNew, args: options.withWindow(tint.apply(to:
                ControlArgs(name: name, cwd: cwd, workspace: workspace, workspaceName: workspaceName,
                            createWorkspace: createWorkspace ? true : nil, noSelect: noSelect ? true : nil,
                            command: command, wait: wait ? true : nil, after: after, before: before)))))
        }
    }
}
