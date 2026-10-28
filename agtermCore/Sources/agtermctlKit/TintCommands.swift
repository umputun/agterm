import ArgumentParser
import agtermCore

/// TintRequest builds the shared `session tint`/`workspace tint` wire form from the CLI spelling, where the
/// one argument is either a color or `clear`.
enum TintRequest {
    static let colorHelp = "A color (\(TintColor.validNamesList)) or 'clear'."
    static let onHelp = "Where the color shows: icon, name, or icon,name. Omitted keeps the current placement, else icon."

    static func validate(_ value: String, on: String?) throws {
        if value == "clear" {
            guard on == nil else { throw ValidationError("--on does not apply to clear") }
            return
        }
        guard TintColor(rawValue: value.lowercased()) != nil else {
            throw ValidationError("tint must be one of: \(TintColor.validNamesList), or clear")
        }
        try validateParts(on, flag: "--on")
    }

    static func validateParts(_ on: String?, flag: String) throws {
        guard let on else { return }
        guard SidebarTint.parseParts(parts(on) ?? []) != nil else {
            throw ValidationError("\(flag) must list icon and/or name, comma-separated")
        }
    }

    static func args(_ value: String, on: String?) -> ControlArgs {
        value == "clear"
            ? ControlArgs(mode: "clear")
            : ControlArgs(mode: "set", tint: value.lowercased(), tintOn: parts(on))
    }

    static func parts(_ on: String?) -> [String]? {
        on.map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }
}

/// TintCreateOptions is the creation tint `session new` and `workspace new` share.
struct TintCreateOptions: ParsableArguments {
    @Option(name: .long, help: "Create it tinted this color (\(TintColor.validNamesList)).") var tint: String?
    @Option(name: .customLong("tint-on"), help: "With --tint: icon, name, or icon,name (default icon).") var tintOn: String?

    func validate() throws {
        guard let tint else {
            guard tintOn == nil else { throw ValidationError("--tint-on requires --tint") }
            return
        }
        guard TintColor(rawValue: tint.lowercased()) != nil else {
            throw ValidationError("--tint must be one of: \(TintColor.validNamesList)")
        }
        try TintRequest.validateParts(tintOn, flag: "--tint-on")
    }

    /// apply copies the creation tint into a `session.new`/`workspace.new` argument bag.
    func apply(to args: ControlArgs) -> ControlArgs {
        var args = args
        args.tint = tint?.lowercased()
        args.tintOn = TintRequest.parts(tintOn)
        return args
    }
}

extension Session {
    struct Tint: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Tint a session's sidebar row (a color, or clear).",
            discussion: """
            session tint red                 tint the icon red (or recolor, keeping the placement)
            session tint green --on name     color the name instead
            session tint blue --on icon,name color both
            session tint clear               remove the tint

            Persists across a relaunch; read back as the tree's tint and tintOn.
            """)
        @Argument(help: ArgumentHelp(TintRequest.colorHelp)) var value: String
        @Option(name: .long, help: ArgumentHelp(TintRequest.onHelp)) var on: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws { try TintRequest.validate(value, on: on) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionTint, target: target.target,
                           args: options.withWindow(TintRequest.args(value, on: on)))
        }
    }
}

extension Workspace {
    struct Tint: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Tint a workspace's own sidebar row (a color, or clear); its sessions keep their own.",
            discussion: """
            workspace tint red --on icon,name
            workspace tint clear

            Persists across a relaunch; read back as the workspace node's tint and tintOn.
            """)
        @Argument(help: ArgumentHelp(TintRequest.colorHelp)) var value: String
        @Option(name: .long, help: ArgumentHelp(TintRequest.onHelp)) var on: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws { try TintRequest.validate(value, on: on) }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceTint, target: target.target,
                           args: options.withWindow(TintRequest.args(value, on: on)))
        }
    }
}
