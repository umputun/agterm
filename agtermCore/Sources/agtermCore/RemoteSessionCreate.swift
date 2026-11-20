/// RemoteSessionCreate is a validated `session.remote.new`: a top-level session created on `host` and attached into
/// a local window's current workspace.
public struct RemoteSessionCreate: Equatable, Sendable {
    /// host is the ssh destination the session is created on.
    public let host: String
    /// originWindow names the Mac host's window to create in; nil uses its one window. Refused for a server.
    public let originWindow: String?
    /// workspaceName is the origin workspace, reused or created; nil takes the local workspace's name.
    public let workspaceName: String?
    public let cwd: String?
    public let command: String?
    /// window is the local window whose current workspace receives the row.
    public let window: String?

    public init(host: String, originWindow: String? = nil, workspaceName: String? = nil, cwd: String? = nil,
                command: String? = nil, window: String? = nil) {
        self.host = host
        self.originWindow = originWindow
        self.workspaceName = workspaceName
        self.cwd = cwd
        self.command = command
        self.window = window
    }

    /// Origin is where on the host the session is created: a Mac's window, or agterm-server, which has none.
    public enum Origin: Equatable, Sendable {
        case mac(window: String)
        case server
    }

    /// Refusal is why a host cannot take the session, worded for the caller.
    public struct Refusal: Error, Equatable, Sendable {
        public let message: String
    }

    /// OriginKind is what a host's `version` reply says it is.
    public enum OriginKind: Equatable, Sendable {
        case mac
        case server
    }

    /// originKind reads `version` strictly: only a Mac reporting Live sessions or agterm-server counts, since any other
    /// host gives no proof the session it creates could be attached.
    public static func originKind(_ version: ControlResult?, host: String) -> Result<OriginKind, Refusal> {
        if let mac = version?.macCatalog {
            guard mac.live == true else {
                return .failure(Refusal(message: "\(host) does not run Live sessions, which a remote session needs"))
            }
            return .success(.mac)
        }
        if version?.headless == true { return .success(.server) }
        return .failure(Refusal(message: "the agterm on \(host) is too old to create sessions for another Mac"))
    }

    // the row always lands appended and selected, so any other placement or creation field is refused, not dropped
    static func parse(_ request: ControlRequest) -> Result<RemoteSessionCreate, ArgumentRejection> {
        let args = request.args
        guard let host = args?.host?.trimmedOrNil else {
            return .failure(ArgumentRejection(message: "session.remote.new requires a host"))
        }
        guard RemoteSession.isHost(host) else {
            return .failure(ArgumentRejection(message: "session.remote.new: not a host ssh can be given"))
        }
        if request.target != nil || args?.targets != nil || args?.workspace != nil || args?.createWorkspace != nil
            || args?.after != nil || args?.before != nil || args?.parent != nil {
            return .failure(ArgumentRejection(message: "a remote session takes no target, workspace id or placement: "
                                              + "it lands in the window's current workspace"))
        }
        if args?.wait != nil || args?.name != nil || args?.noSelect != nil || args?.tint != nil || args?.tintOn != nil {
            return .failure(ArgumentRejection(message: "a remote session takes no --wait, --name, --no-select or tint"))
        }
        if args?.opID != nil {
            return .failure(ArgumentRejection(message: "a remote session takes no operation id"))
        }
        // blank is refused, not read as omitted: omitted takes the local workspace's name, a different destination
        if let name = args?.workspaceName, name.trimmedOrNil == nil {
            return .failure(ArgumentRejection(message: "workspace name must not be blank"))
        }
        return .success(RemoteSessionCreate(host: host, originWindow: args?.originWindow?.trimmedOrNil,
                                            workspaceName: args?.workspaceName?.trimmedOrNil, cwd: args?.cwd,
                                            command: args?.command, window: args?.window?.trimmedOrNil))
    }

    /// arguments is the origin's `agtermctl` command line. The origin keeps its own selection: the session is
    /// wanted here, not there.
    public func arguments(origin: Origin, workspaceName: String) -> [String] {
        var arguments = ["session", "new"]
        if case .mac(let window) = origin { arguments.append("--window=" + window) }
        arguments += ["--workspace-name=" + workspaceName, "--create-workspace", "--no-select"]
        return arguments + RemoteSession.optionArgument("--cwd", cwd) + RemoteSession.optionArgument("--command", command)
    }
}
