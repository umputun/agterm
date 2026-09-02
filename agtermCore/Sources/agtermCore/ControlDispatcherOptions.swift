public struct ControlSessionTypeOptions: Equatable, Sendable {
    public let text: String
    public let select: Bool
    /// The parsed pane, nil for the main one. The dispatcher owns the spelling, so the role and position
    /// aliases the CLI accepts resolve here rather than being matched again in the host.
    public let pane: StatusPane?

    public init(text: String, select: Bool, pane: StatusPane?) {
        self.text = text
        self.select = select
        self.pane = pane
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

    public init(command: String, cwd: String?, wait: Bool, sizePercent: Int?, backgroundColor: String?,
                follow: Bool = false, pane: OverlayPane? = nil) {
        self.command = command
        self.cwd = cwd
        self.wait = wait
        self.sizePercent = sizePercent
        self.backgroundColor = backgroundColor
        self.follow = follow
        self.pane = pane
    }
}

public struct ControlSessionBackgroundOptions: Equatable, Sendable {
    public let watermark: BackgroundWatermark?

    public init(watermark: BackgroundWatermark?) {
        self.watermark = watermark
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
