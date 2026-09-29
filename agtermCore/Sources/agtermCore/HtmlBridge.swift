import Foundation

extension ControlWire {
    /// invalidRequestMessage is the error for a request that does not decode, shared by the socket and the page
    /// bridge. It reports the `DecodingError`'s context, which names the rejected `cmd`; `localizedDescription`
    /// does not, and `DecodingError.debugDescription` is newer than the deployment target.
    public static func invalidRequestMessage(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "invalid request: \(error.localizedDescription)" }
        switch decoding {
        case .dataCorrupted(let context), .keyNotFound(_, let context),
             .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "invalid request: \(context.debugDescription)"
        @unknown default:
            return "invalid request: \(String(describing: decoding))"
        }
    }
}

/// HtmlBridgePage is where a requesting page sits when its request arrives: the window, the session and the
/// pane slot (nil for the session-wide one) holding it.
public struct HtmlBridgePage: Sendable, Equatable {
    public let window: String?
    public let session: UUID
    public let pane: OverlayPane?

    public init(window: String?, session: UUID, pane: OverlayPane?) {
        self.window = window
        self.session = session
        self.pane = pane
    }
}

/// HtmlBridgeError is why a page's message was not turned into a request.
public struct HtmlBridgeError: Error, Equatable, Sendable {
    public let message: String

    static func unsupported(_ cmd: String) -> HtmlBridgeError {
        HtmlBridgeError(message: "\(cmd) cannot be sent from a page")
    }
}

/// HtmlBridge turns a page's message into the socket's request, so a page speaks the wire protocol and nothing
/// else. What the page left out is filled from where it sits, and only there: an explicit target, `active`,
/// window or batch resolves exactly as it would over the socket.
public enum HtmlBridge {
    // each needs more than one request and reply: a stream handed over, or work done after the reply
    private static let refused: Set<Command> = [.zmxPresent, .sessionOverlayJobRun, .zmxReset]
    // commands that address no session, or address it some other way than by `target`
    private static let notSessionTargeted: Set<Command> = [.sessionNew, .sessionGo, .sessionOverlayJobRun]
    // session commands outside the `session.` names; `ask.open` joins them unless it asks in the window's GUI
    private static let sessionTargeted: Set<Command> = [.notify, .fontInc, .fontDec, .fontReset]
    private static let ownOverlay: Set<Command> = [.sessionOverlayClose, .sessionOverlayReload,
                                                   .sessionOverlayNavigate, .sessionOverlaySubmit]
    // these take their window as `target`, not as `args.window`
    private static let windowTargeted: Set<Command> = [.windowClose, .windowSelect, .windowRename, .windowDelete,
                                                       .windowResize, .windowMove, .windowZoom, .windowFullscreen,
                                                       .windowMinimize]
    // their ids name something else (a remote session, dashboard cells), and they still land in a local window
    private static let placedLocally: Set<Command> = [.zmxAttach, .dashboard]

    public static func request(from data: Data, page: HtmlBridgePage) -> Result<ControlRequest, HtmlBridgeError> {
        let decoded: ControlRequest
        do {
            decoded = try JSONDecoder().decode(ControlRequest.self, from: data)
        } catch {
            return .failure(HtmlBridgeError(message: ControlWire.invalidRequestMessage(error)))
        }
        guard !refused.contains(decoded.cmd) else { return .failure(.unsupported(decoded.cmd.rawValue)) }
        return .success(withDefaults(decoded, page: page))
    }

    private static func withDefaults(_ request: ControlRequest, page: HtmlBridgePage) -> ControlRequest {
        var request = request
        var args = request.args ?? ControlArgs()
        let addressed = request.target != nil || args.targets != nil || args.window != nil
        if request.cmd == .sessionOverlayReload, args.current == nil { args.current = true }
        if placedLocally.contains(request.cmd) {
            if args.window == nil { args.window = page.window }
        } else if !addressed {
            if isSessionTargeted(request.cmd, args: args) {
                request.target = page.session.uuidString
                if ownOverlay.contains(request.cmd), args.pane == nil { args.pane = page.pane?.rawValue }
            } else if windowTargeted.contains(request.cmd) {
                request.target = page.window
            } else {
                args.window = page.window
            }
        }
        request.args = args == ControlArgs() ? nil : args
        return request
    }

    private static func isSessionTargeted(_ cmd: Command, args: ControlArgs) -> Bool {
        if cmd == .askOpen { return args.style != "gui" }
        return (cmd.rawValue.hasPrefix("session.") && !notSessionTargeted.contains(cmd)) || sessionTargeted.contains(cmd)
    }
}
