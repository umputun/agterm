public struct ControlSessionTypeOptions: Equatable, Sendable {
    public let text: String
    public let select: Bool
    /// The parsed pane, nil for the main one. The dispatcher owns the spelling, so the role and position
    /// aliases the CLI accepts resolve here rather than being matched again in the host.
    public let pane: StatusPane?
    public let paneID: String?

    public init(text: String, select: Bool, pane: StatusPane?, paneID: String? = nil) {
        self.text = text
        self.select = select
        self.pane = pane
        self.paneID = paneID
    }
}

public struct ControlSessionOverlayOpenOptions: Equatable, Sendable {
    public let command: String
    public let cwd: String?
    public let wait: Bool
    public let sizePercent: Int?
    public let backgroundColor: String?
    public let follow: Bool
    /// The pane to cover, nil for the session-wide overlay. A pane overlay is always full, so this and
    /// `sizePercent` are mutually exclusive (rejected in the dispatcher).
    public let pane: OverlayPane?
    /// page is the file or web page to show instead of running `command`, which is then empty, as is `cwd`.
    public let page: HtmlSource?
    public let navigation: Bool
    public let javascript: Bool
    public let chromeless: Bool
    public let persistent: Bool
    public let browse: Bool

    public init(command: String, cwd: String?, wait: Bool, sizePercent: Int?, backgroundColor: String?,
                follow: Bool = false, pane: OverlayPane? = nil, page: HtmlSource? = nil, navigation: Bool = false,
                javascript: Bool = false, chromeless: Bool = false, persistent: Bool = false, browse: Bool = false) {
        self.command = command
        self.cwd = cwd
        self.wait = wait
        self.sizePercent = sizePercent
        self.backgroundColor = backgroundColor
        self.follow = follow
        self.pane = pane
        self.page = page
        self.navigation = navigation
        self.javascript = javascript
        self.chromeless = chromeless
        self.persistent = persistent
        self.browse = browse
    }
}

public struct ControlSessionBackgroundOptions: Equatable, Sendable {
    public let watermark: BackgroundWatermark?
    /// pane selects the override to write; nil writes the session default.
    public let pane: StatusPane?

    public init(watermark: BackgroundWatermark?, pane: StatusPane? = nil) {
        self.watermark = watermark
        self.pane = pane
    }
}

public struct ControlSessionTextOptions: Equatable, Sendable {
    /// The parsed pane, nil for the on-screen one. `paneID` still overrides it when the token resolves.
    public let pane: StatusPane?
    public let paneID: String?
    public let all: Bool
    public let lines: Int?

    public init(pane: StatusPane?, paneID: String? = nil, all: Bool, lines: Int?) {
        self.pane = pane
        self.paneID = paneID
        self.all = all
        self.lines = lines
    }
}

/// `session.overlay.text`'s inputs. `pane` is an `OverlayPane` rather than `ControlSessionTextOptions`'
/// `StatusPane`: the overlay family takes only `left`/`right`, `scratch` having no pane to cover. Both are
/// parsed by the dispatcher, so the host never re-parses a vocabulary it could widen by accident.
public struct ControlSessionOverlayTextOptions: Equatable, Sendable {
    public let pane: OverlayPane?
    public let all: Bool
    public let lines: Int?

    public init(pane: OverlayPane?, all: Bool, lines: Int?) {
        self.pane = pane
        self.all = all
        self.lines = lines
    }
}

/// ControlSessionRestartOptions is the parsed `session.restart` payload. At least one of `pane` and
/// `paneID` is set; the host resolves them against the live slots.
public struct ControlSessionRestartOptions: Equatable, Sendable {
    /// maxCommandBytes bounds the shell line in UTF-8 bytes. It travels in the new shell's argv, inside
    /// the session host's 64 KiB creation frame beside the pane's environment.
    public static let maxCommandBytes = 4096

    /// command is the shell line to run; nil replays the pane's foreground program instead.
    public let command: String?
    public let pane: StatusPane?
    public let paneID: String?

    public init(command: String?, pane: StatusPane?, paneID: String? = nil) {
        self.command = command
        self.pane = pane
        self.paneID = paneID
    }
}

/// ControlRestartReceipt is what a successful `session.restart` proves: the pane's shell was replaced.
/// The pids are the daemon leaders, the pane's root shells, not the program the caller's line starts.
public struct ControlRestartReceipt: Codable, Equatable, Sendable {
    public let paneID: String
    public let oldPid: Int32
    public let newPid: Int32
    /// replayedArgv is the foreground program a restart without a command asked the new shell to run;
    /// nil when the caller supplied the line. It is what was requested, not proof the program started.
    public let replayedArgv: [String]?

    public init(paneID: String, oldPid: Int32, newPid: Int32, replayedArgv: [String]? = nil) {
        self.paneID = paneID
        self.oldPid = oldPid
        self.newPid = newPid
        self.replayedArgv = replayedArgv
    }
}
