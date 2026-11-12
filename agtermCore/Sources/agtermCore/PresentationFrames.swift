import Foundation

/// PresentationPane names a pane of the origin session on the wire. A main or split pane travels as its stable
/// identity, never as a left/right role, so a swap or promotion on either Mac cannot misroute it.
public enum PresentationPane: Equatable, Sendable, Codable {
    case identity(UUID)
    case scratch

    private static let scratchName = "scratch"

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text == Self.scratchName {
            self = .scratch
            return
        }
        guard let id = UUID(uuidString: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "pane is neither scratch nor a uuid"))
        }
        self = .identity(id)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .identity(let id): try container.encode(id.uuidString)
        case .scratch: try container.encode(Self.scratchName)
        }
    }
}

/// PresentationMode is what a viewer asks to be: a mirror beside the origin, or the sole presenter.
public enum PresentationMode: String, Codable, Sendable {
    case mirror, presenter
}

/// PresentationHello opens a stream in both directions and carries what each side can speak.
public struct PresentationHello: Codable, Equatable, Sendable {
    public var version: Int
    public var kinds: [String]
    public var mode: PresentationMode

    public init(version: Int, kinds: [String], mode: PresentationMode) {
        self.version = version
        self.kinds = kinds
        self.mode = mode
    }
}

/// PresentationStatus is a session's full non-idle agent status. Idle travels as an absent status.
public struct PresentationStatus: Codable, Equatable, Sendable {
    public var status: AgentStatus
    public var blink: Bool
    public var color: String?
    public var shape: StatusShape?
    public var pane: PresentationPane?
    /// Epoch seconds on the origin's clock.
    public var changedAt: Double?

    public init(status: AgentStatus, blink: Bool, color: String?, shape: StatusShape?, pane: PresentationPane?,
                changedAt: Double?) {
        self.status = status
        self.blink = blink
        self.color = color
        self.shape = shape
        self.pane = pane
        self.changedAt = changedAt
    }
}

/// PresentationHud is the origin's live HUD. `generation` counts its publications; a withdrawal carries
/// none, and the frame's `rev` is what orders it against a replacement.
public struct PresentationHud: Codable, Equatable, Sendable {
    public var spec: HudSpec
    /// The pane a pane-scoped panel sits over; nil for a session-wide one. `HudSpec` holds only the position
    /// inside that area.
    public var pane: PresentationPane?
    public var generation: Int
    /// Seconds until the origin hides the panel, sampled when the frame was built; nil for a persistent one.
    public var remaining: Double?

    public init(spec: HudSpec, pane: PresentationPane?, generation: Int, remaining: Double?) {
        self.spec = spec
        self.pane = pane
        self.generation = generation
        self.remaining = remaining
    }
}

/// PresentationNotify is one control-origin notification. It is a live event, never part of a snapshot.
public struct PresentationNotify: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var pane: PresentationPane?
    public var source: String

    public init(title: String, body: String, pane: PresentationPane?, source: String) {
        self.title = title
        self.body = body
        self.pane = pane
        self.source = source
    }
}

/// PresentationSound is a status sound the origin hands its presenter to play instead of playing it itself.
/// A nil `name` is the presenter's own Settings blocked sound, so each Mac's choice applies where it plays.
public struct PresentationSound: Codable, Equatable, Sendable {
    public var name: String?

    public init(name: String?) {
        self.name = name
    }
}

/// PresentationAsk is an ask the origin hands its presenter to draw. `owner` is the presenter generation it
/// was handed under, and every answer echoes it, so one arriving after a handback is recognisably stale.
public struct PresentationAsk: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var message: String?
    public var buttons: [ControlAskButton]
    public var defaultID: String?
    public var destructiveID: String?
    public var style: ControlAskStyle
    public var align: ControlAskAlignment
    public var width: Int?
    /// The origin's pane the dialog covers, nil for the whole session.
    public var pane: PresentationPane?
    public var owner: Int
    /// input and choices carry the ask's form; a presenter without `ask.form` never receives either.
    public var input: AskInputForm?
    public var choices: AskChoiceForm?
    public var cancelID: String?

    public init(_ ask: PendingAsk, pane: PresentationPane?, owner: Int) {
        id = ask.id
        title = ask.title
        message = ask.message
        buttons = ask.buttons
        defaultID = ask.defaultID
        destructiveID = ask.destructiveID
        style = ask.style
        align = ask.align
        width = ask.width
        self.pane = pane
        self.owner = owner
        cancelID = ask.cancelID
        switch ask.form {
        case .input(let form): input = form
        case .choices(let form): choices = form
        case nil: break
        }
    }

    /// The form the request carries, input first should a malformed frame carry both.
    public var form: AskForm? {
        if let input { return .input(input) }
        return choices.map(AskForm.choices)
    }

    /// Whether the presenter must understand `ask.form` to show this ask as the origin means it.
    public var needsFormSupport: Bool { input != nil || choices != nil || cancelID != nil }

    /// Whether the presenter must also understand `ask.other` to show the choice list's free-form row.
    public var needsOtherSupport: Bool { choices?.other != nil }

    /// Whether the request, and the largest answer it can produce, each fit one stream frame, measured through
    /// the codec with the widest counters. A text answer is tried with every button and the text cap at twice
    /// its bytes, the worst escaping the allowed characters reach; a selection alone names only ids the request
    /// already carried, but a checkbox list's free-form text rides beside every id.
    public func fitsFrames() -> Bool {
        guard Self.fits(.askRequest(self)) else { return false }
        let text = String(repeating: "\"", count: AskInputForm.maxTextBytes)
        if input != nil {
            return buttons.allSatisfy { Self.fits(.askResolve(PresentationAskAnswer(id: id, owner: owner, button: $0.id, text: text))) }
        }
        guard let choices, choices.other != nil else { return true }
        let selected = choices.multiple ? choices.choices.map(\.id) : []
        return buttons.allSatisfy {
            Self.fits(.askResolve(PresentationAskAnswer(id: id, owner: owner, button: $0.id, text: text, selected: selected)))
        }
    }

    private static func fits(_ body: PresentationFrame.Body) -> Bool {
        (try? PresentationCodec.encode(PresentationFrame(gen: .max, rev: .max, body: body))) != nil
    }
}

/// PresentationAskAnswer is the presenter's answer: a button id, or nil for a dismissal with Esc or Command-W.
/// The origin derives label and index from the buttons it stored and checks `text` and `selected` against
/// the form it stored.
public struct PresentationAskAnswer: Codable, Equatable, Sendable {
    public var id: String
    public var owner: Int
    public var button: String?
    public var text: String?
    public var selected: [String]?

    public init(id: String, owner: Int, button: String?, text: String? = nil, selected: [String]? = nil) {
        self.id = id
        self.owner = owner
        self.button = button
        self.text = text
        self.selected = selected
    }
}

/// PresentationAskRef names one handed-over ask, for a refusal or a dismissal.
public struct PresentationAskRef: Codable, Equatable, Sendable {
    public var id: String
    public var owner: Int

    public init(id: String, owner: Int) {
        self.id = id
        self.owner = owner
    }
}

/// PresentationOverlay asks the presenter to show an overlay whose program runs on the origin: the viewer
/// opens a local surface running the job's helper over ssh. Nothing of the command or its environment is
/// sent; the helper gets those from the origin when it claims the job.
public struct PresentationOverlay: Codable, Equatable, Sendable {
    public var job: String
    /// The origin's pane the overlay covers, nil for the session-wide slot.
    public var pane: PresentationPane?
    public var sizePercent: Int?
    /// width and height are the `--width`/`--height` point overrides, sent only to a presenter listing
    /// `PresentationHub.overlayPointsKind`.
    public var width: Int?
    public var height: Int?
    public var backgroundColor: String?
    public var follow: Bool
    public var wait: Bool
    /// token is the offer token the presenter passes to the job's helper, sent only to one listing `job.token`.
    public var token: String?

    public init(job: String, pane: PresentationPane?, sizePercent: Int?, points: OverlayPointSize = OverlayPointSize(),
                backgroundColor: String?, follow: Bool, wait: Bool, token: String? = nil) {
        self.job = job
        self.pane = pane
        self.sizePercent = sizePercent
        width = points.width
        height = points.height
        self.backgroundColor = backgroundColor
        self.follow = follow
        self.wait = wait
        self.token = token
    }

    public var points: OverlayPointSize {
        get { OverlayPointSize(width: width, height: height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }
}

/// PresentationOverlayChange names one remote overlay job, with a size for a resize.
public struct PresentationOverlayChange: Codable, Equatable, Sendable {
    public var job: String
    public var sizePercent: Int?
    public var width: Int?
    public var height: Int?

    public init(job: String, sizePercent: Int? = nil, points: OverlayPointSize = OverlayPointSize()) {
        self.job = job
        self.sizePercent = sizePercent
        width = points.width
        height = points.height
    }

    public var points: OverlayPointSize {
        get { OverlayPointSize(width: width, height: height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }
}

/// PresentationPageSource is a handed-over page's full source on the origin: a file the viewer fetches over the
/// page channel, with the grant that bounds which files it may ask for, or a complete URL it loads itself.
/// The image, markdown and text cases are pages the viewer builds itself from bytes it fetches over the channel;
/// they go only to a presenter listing `PresentationHub.pageContentKind`, since an older one fails the whole
/// stream on a case it cannot decode.
public enum PresentationPageSource: Codable, Equatable, Sendable {
    case file(path: String, grantRoot: String?)
    case url(String)
    /// image carries the picture's oriented pixel size, which the viewer turns into points for its own screen.
    case image(path: String, width: Int, height: Int)
    case markdown(path: String)
    case text(path: String, line: Int?)
    /// document goes only to a presenter also listing `PresentationHub.pageDocumentKind`, for the same reason.
    case document(path: String)
    /// forwarded is a URL on a headless origin's own loopback, which the presenter reaches through an ssh forward
    /// it opens; only a presenter listing `page.forward` is sent one.
    case forwarded(String)

    /// usesChannel says the viewer fetches this page over a page channel, which a single-use claim opens.
    public var usesChannel: Bool {
        switch self {
        case .url, .forwarded: return false
        case .file, .image, .markdown, .text, .document: return true
        }
    }

    /// isContent says this is a page the viewer builds from fetched bytes rather than loads as HTML.
    public var isContent: Bool {
        switch self {
        case .file, .url, .forwarded: return false
        case .image, .markdown, .text, .document: return true
        }
    }
}

/// PresentationPage asks the presenter to show a page the origin opened. `page` is the origin's page id, which
/// the presenter never reuses as its own; `token` claims the page channel and is single-use.
public struct PresentationPage: Codable, Equatable, Sendable {
    public var page: String
    public var token: String
    public var source: PresentationPageSource
    /// identity is the display text the identity strip shows, never used to load anything.
    public var identity: String
    public var chromeless: Bool
    public var javascript: Bool
    public var navigation: Bool
    public var browse: Bool
    public var persistent: Bool
    public var backgroundColor: String?
    /// pane is the origin's pane the page covers, nil for the session-wide slot.
    public var pane: PresentationPane?
    public var sizePercent: Int?
    public var width: Int?
    public var height: Int?
    public var follow: Bool
    /// markdownLinks is the link grant the origin froze at open; nil, and left out of the frame, for any other page.
    public var markdownLinks: MarkdownLinkGrant?
    /// textLog makes a text page a log page; sent only to a presenter listing `page.text`, which an older one ignores.
    public var textLog: TextLog?
    /// textSeed is the text state a re-offered page resumes with, applied before its first render and report.
    public var textSeed: PresentationTextState?

    public init(page: String, token: String, source: PresentationPageSource, identity: String, chromeless: Bool,
                javascript: Bool, navigation: Bool, browse: Bool, persistent: Bool, backgroundColor: String?,
                pane: PresentationPane?, sizePercent: Int?, points: OverlayPointSize = OverlayPointSize(),
                follow: Bool, markdownLinks: MarkdownLinkGrant? = nil, textLog: TextLog? = nil,
                textSeed: PresentationTextState? = nil) {
        self.markdownLinks = markdownLinks
        self.textLog = textLog
        self.textSeed = textSeed
        self.page = page
        self.token = token
        self.source = source
        self.identity = identity
        self.chromeless = chromeless
        self.javascript = javascript
        self.navigation = navigation
        self.browse = browse
        self.persistent = persistent
        self.backgroundColor = backgroundColor
        self.pane = pane
        self.sizePercent = sizePercent
        width = points.width
        height = points.height
        self.follow = follow
    }

    public var points: OverlayPointSize {
        get { OverlayPointSize(width: width, height: height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }
}

/// PresentationPageChange names one handed-over page by the origin's id, with a reason when the presenter
/// refuses it or took it down because its channel ended.
public struct PresentationPageChange: Codable, Equatable, Sendable {
    /// channelLost is the reason of a page a presenter took down because its channel ended, not because anyone closed it.
    public static let channelLost = "channel-lost"

    public var page: String
    public var reason: String?

    public init(page: String, reason: String? = nil) {
        self.page = page
        self.reason = reason
    }
}

/// PresentationPageAction is what the origin asks of a handed-over page. The text actions go only to a presenter
/// listing `page.text`: an older one cannot decode them and would end the stream.
public enum PresentationPageAction: String, Codable, Sendable {
    case hide, show, reloadOriginal, reloadCurrent, back, forward, browser, resize
    case follow, search, wrap, changes

    /// answersWithResult says the presenter answers this action with a `pageResult` rather than only `appliedSeq`.
    public var answersWithResult: Bool {
        switch self {
        case .follow, .search, .wrap, .changes: return true
        case .hide, .show, .reloadOriginal, .reloadCurrent, .back, .forward, .browser, .resize: return false
        }
    }
}

/// PresentationTextStep is a one-shot move on a text page: a search step or close, or a diff change step.
public enum PresentationTextStep: String, Codable, Sendable {
    case next, prev, close
}

/// PresentationPageCommand is one origin request for a handed-over page. `seq` grows per page, and the
/// presenter echoes the last one it applied in `PresentationPageState.appliedSeq`.
public struct PresentationPageCommand: Codable, Equatable, Sendable {
    public var page: String
    public var seq: Int
    public var action: PresentationPageAction
    public var sizePercent: Int?
    public var width: Int?
    public var height: Int?
    /// merge asks a resize to keep the axes it does not name, for a picture the presenter sized itself; nil, and
    /// left out of the frame, for every other command, which replaces the size whole.
    public var merge: Bool?
    /// toggle is a follow or wrap request's mode.
    public var toggle: ControlToggleMode?
    /// query is a search request's new query; a search carries either it or a step.
    public var query: String?
    public var step: PresentationTextStep?

    public init(page: String, seq: Int, action: PresentationPageAction, sizePercent: Int? = nil,
                points: OverlayPointSize = OverlayPointSize(), merge: Bool? = nil, toggle: ControlToggleMode? = nil,
                query: String? = nil, step: PresentationTextStep? = nil) {
        self.page = page
        self.seq = seq
        self.action = action
        self.sizePercent = sizePercent
        width = points.width
        height = points.height
        self.merge = merge
        self.toggle = toggle
        self.query = query
        self.step = step
    }

    public var points: OverlayPointSize {
        get { OverlayPointSize(width: width, height: height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }
}

/// PresentationPageState is what a handed-over page shows on the presenter. `address` is the origin's logical
/// address, never the presenter's own scheme URL. Strings are bounded before sending, since the page writes
/// its title and a long one must not cost a frame.
public struct PresentationPageState: Codable, Equatable, Sendable {
    public static let maxTitle = 1024
    public static let maxAddress = 8192
    public static let maxError = 1024

    public var page: String
    public var title: String?
    public var address: String?
    public var load: HtmlLoadState
    public var error: String?
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var hidden: Bool
    public var appliedSeq: Int
    /// text is a text page's live state, sent only to an origin listing `page.text`.
    public var text: PresentationTextState?

    public init(page: String, title: String?, address: String?, load: HtmlLoadState, error: String?,
                canGoBack: Bool, canGoForward: Bool, hidden: Bool, appliedSeq: Int, text: PresentationTextState? = nil) {
        self.page = page
        self.title = title.map { String($0.prefix(Self.maxTitle)) }
        self.address = address.map { String($0.prefix(Self.maxAddress)) }
        self.load = load
        self.error = error.map { String($0.prefix(Self.maxError)) }
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.hidden = hidden
        self.appliedSeq = appliedSeq
        self.text = text
    }
}

/// PresentationTextState is a text page's live state on the presenter: a log page's following and last read, the
/// search query under the presenter's revision with its counts, wrap, and a diff page's changes.
public struct PresentationTextState: Codable, Equatable, Sendable {
    public var following: Bool?
    public var log: TextLogReport?
    public var query: String?
    public var revision: Int
    public var matches: Int?
    public var current: Int?
    public var wrap: Bool
    public var changes: TextChanges?

    public init(following: Bool? = nil, log: TextLogReport? = nil, query: String? = nil, revision: Int = 0,
                matches: Int? = nil, current: Int? = nil, wrap: Bool = false, changes: TextChanges? = nil) {
        self.following = following
        self.log = log
        self.query = query.map { String($0.prefix(TextSearch.maxQuery)) }
        self.revision = revision
        self.matches = matches
        self.current = current
        self.wrap = wrap
        self.changes = changes
    }
}

/// PresentationPageResult answers one text action by its `seq`, with the page's text state after it, so the origin
/// replies with state its tree already shows.
public struct PresentationPageResult: Codable, Equatable, Sendable {
    public static let maxText = 1024

    public var page: String
    public var seq: Int
    public var ok: Bool
    public var text: String?
    public var error: String?
    public var state: PresentationTextState?

    public init(page: String, seq: Int, ok: Bool, text: String? = nil, error: String? = nil,
                state: PresentationTextState? = nil) {
        self.page = page
        self.seq = seq
        self.ok = ok
        self.text = text.map { String($0.prefix(Self.maxText)) }
        self.error = error.map { String($0.prefix(Self.maxText)) }
        self.state = state
    }
}

/// PresentationRespawns is how often the origin respawned each of a session's panes, by daemon name, in one
/// origin app lifetime: `epoch` changes on every launch, so a counter that restarted is never read as older.
public struct PresentationRespawns: Codable, Equatable, Sendable {
    public let epoch: String
    public let generations: [String: Int]

    public init(epoch: String, generations: [String: Int]) {
        self.epoch = epoch
        self.generations = generations
    }
}

/// PresentationLinkClick is a path clicked in a pane the presenter shows, for the origin to open. `pane` is the
/// origin's identity of that pane. The mode decodes leniently, an unknown one as `overlay`, because a frame that
/// fails to decode closes the whole stream.
public struct PresentationLinkClick: Codable, Equatable, Sendable {
    public var raw: String
    public var pane: UUID
    public var mode: LinkOpenMode

    private enum CodingKeys: String, CodingKey { case raw, pane, mode }

    public init(raw: String, pane: UUID, mode: LinkOpenMode) {
        self.raw = raw
        self.pane = pane
        self.mode = mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        raw = try container.decode(String.self, forKey: .raw)
        pane = try container.decode(UUID.self, forKey: .pane)
        mode = (try? container.decode(String.self, forKey: .mode)).flatMap(LinkOpenMode.init(rawValue:)) ?? .overlay
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(raw, forKey: .raw)
        try container.encode(pane, forKey: .pane)
        try container.encode(mode.rawValue, forKey: .mode)
    }
}

/// PresentationLinkRefusal is the origin's answer to a forwarded click it did not open. An unknown reason decodes as
/// `notOpened`, for the same reason the click's mode decodes leniently.
public struct PresentationLinkRefusal: Codable, Equatable, Sendable {
    public var reason: RemoteLinkRefusal

    private enum CodingKeys: String, CodingKey { case reason }

    public init(reason: RemoteLinkRefusal) { self.reason = reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = (try? container.decode(String.self, forKey: .reason)).flatMap(RemoteLinkRefusal.init(rawValue:)) ?? .notOpened
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason.rawValue, forKey: .reason)
    }
}

/// PresentationInfo is a session's local info line as the origin mirrors it. The viewer parses the source itself and
/// runs no timer: `hideAfter` is the configured value for read-back, and the origin's expiry arrives as a clear.
public struct PresentationInfo: Codable, Equatable, Sendable {
    public var source: String
    public var markdown: Bool
    public var hideAfter: Double

    public init(source: String, markdown: Bool, hideAfter: Double) {
        self.source = source
        self.markdown = markdown
        self.hideAfter = hideAfter
    }
}

/// PresentationSnapshot is the replaceable state a subscriber starts from.
public struct PresentationSnapshot: Codable, Equatable, Sendable {
    public var status: PresentationStatus?
    public var hud: PresentationHud?
    public var context: String?
    public var layout: PresentationLayout?
    /// respawns is nil from an origin that predates parent respawn.
    public var respawns: PresentationRespawns?
    /// info is nil from an origin that predates the info line, or with no local line set.
    public var info: PresentationInfo?

    public init(status: PresentationStatus?, hud: PresentationHud?, context: String? = nil, layout: PresentationLayout? = nil,
                respawns: PresentationRespawns? = nil, info: PresentationInfo? = nil) {
        self.status = status
        self.hud = hud
        self.context = context
        self.layout = layout
        self.respawns = respawns
        self.info = info
    }
}

/// PresentationPendingChunk is slice `index` of the frames a headless origin hands a new presenter at once: base64
/// of their encoded array, cut at a byte count so an entry of any size stays behind the commit.
public struct PresentationPendingChunk: Codable, Equatable, Sendable {
    public var index: Int
    public var data: String

    public init(index: Int, data: String) {
        self.index = index
        self.data = data
    }
}

/// PresentationPendingBatch cuts a batch into chunks and gathers chunks back into it.
public struct PresentationPendingBatch: Sendable {
    public enum Failure: Error, Equatable {
        case outOfOrder(Int)
        case malformed
    }

    static let chunkBytes = CatalogCodec.chunkBytes

    private var data = Data()
    private var count = 0
    private var failure: Failure?

    public init() {}

    /// chunks is `bodies` encoded as one array and cut into slices.
    public static func chunks(_ bodies: [PresentationFrame.Body]) throws -> [PresentationPendingChunk] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(bodies.map { PresentationFrame(gen: 0, rev: 0, body: $0) })
        return stride(from: 0, to: data.count, by: chunkBytes).enumerated().map { index, offset in
            PresentationPendingChunk(index: index, data: data[offset..<min(offset + chunkBytes, data.count)].base64EncodedString())
        }
    }

    public mutating func add(_ chunk: PresentationPendingChunk) {
        guard failure == nil else { return }
        guard chunk.index == count, let bytes = Data(base64Encoded: chunk.data) else {
            failure = .outOfOrder(chunk.index)
            return
        }
        data.append(bytes)
        count += 1
    }

    /// commit yields the gathered batch and starts over, nothing for a commit with no chunks before it.
    public mutating func commit() throws -> [PresentationFrame.Body] {
        defer { self = PresentationPendingBatch() }
        if let failure { throw failure }
        guard count > 0 else { return [] }
        guard let frames = try? JSONDecoder().decode([PresentationFrame].self, from: data) else { throw Failure.malformed }
        return frames.map(\.body)
    }
}

/// PresentationFrame is one line of the presentation stream. `gen` is the connection generation and `rev` a
/// revision monotonic within it, so a receiver can drop anything left over from an earlier connection.
public struct PresentationFrame: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case hello(PresentationHello)
        case ping
        case ack
        case snapshot(PresentationSnapshot)
        case status(PresentationStatus?)
        case context(String?)
        case info(PresentationInfo?)
        case layout(PresentationLayout)
        case hud(PresentationHud?)
        case notify(PresentationNotify)
        case sound(PresentationSound)
        /// A viewer asking to be the session's sole presenter. Sent only after the origin's hello offered it.
        case presenterAcquire
        case presenterGranted
        /// The role is held by another viewer; this one stays a mirror until it reconnects.
        case presenterRefused
        case askRequest(PresentationAsk)
        case askResolve(PresentationAskAnswer)
        /// The presenter cannot show the ask, so the origin takes it back.
        case askRejected(PresentationAskRef)
        /// The ask ended on the origin; the presenter takes its dialog down without answering.
        case askDismiss(PresentationAskRef)
        case pickRequest(PresentationPick)
        case pickResolve(PresentationPickAnswer)
        /// The presenter cannot show the pick, so the origin takes it back.
        case pickRejected(PresentationPickRef)
        /// The pick ended on the origin; the presenter takes its picker down without answering.
        case pickDismiss(PresentationPickRef)
        case overlayRequest(PresentationOverlay)
        /// The presenter cannot show the overlay; the origin fails the job without launching anything.
        case overlayRejected(PresentationOverlayChange)
        case overlayClose(PresentationOverlayChange)
        case overlayResize(PresentationOverlayChange)
        /// The viewer closed its surface, which frees a slot held only for a `--wait` surface.
        case overlayClosed(PresentationOverlayChange)
        case pageRequest(PresentationPage)
        /// pageRejected: the presenter cannot show the page, so the origin ends it without waiting for a claim.
        case pageRejected(PresentationPageChange)
        case pageClose(PresentationPageChange)
        /// pageClosed: the presenter took the page down, so the origin ends it, keeping an answer it recorded.
        case pageClosed(PresentationPageChange)
        case pageCommand(PresentationPageCommand)
        case pageState(PresentationPageState)
        /// pageResult: the presenter's answer to one text action, by its sequence number.
        case pageResult(PresentationPageResult)
        /// The origin respawned a pane's shell under the same daemon name; carries that pane's new count alone.
        case respawn(PresentationRespawns)
        /// linkClick: the presenter forwards a path clicked in one of the session's panes for the origin to open.
        case linkClick(PresentationLinkClick)
        /// linkRefused: the origin did not open a forwarded click.
        case linkRefused(PresentationLinkRefusal)
        /// pendingChunk carries a slice of what a headless origin held for a new presenter, applied only at the commit.
        case pendingChunk(PresentationPendingChunk)
        /// pendingCommit applies every chunk since the presenter was granted, in order.
        case pendingCommit
        /// A kind this build does not speak. Kept, with its ordering, so a newer peer does not break the stream.
        case unknown(String)

        var kind: String {
            switch self {
            case .hello: return "hello"
            case .ping: return "ping"
            case .ack: return "ack"
            case .snapshot: return "snapshot"
            case .status: return "status"
            case .context: return "context"
            case .info: return "info"
            case .layout: return "layout"
            case .hud: return "hud"
            case .notify: return "notify"
            case .sound: return "sound"
            case .presenterAcquire: return "presenter.acquire"
            case .presenterGranted: return "presenter.granted"
            case .presenterRefused: return "presenter.refused"
            case .askRequest: return "ask.request"
            case .askResolve: return "ask.resolve"
            case .askRejected: return "ask.rejected"
            case .askDismiss: return "ask.dismiss"
            case .pickRequest: return "pick.request"
            case .pickResolve: return "pick.resolve"
            case .pickRejected: return "pick.rejected"
            case .pickDismiss: return "pick.dismiss"
            case .overlayRequest: return "overlay.request"
            case .overlayRejected: return "overlay.rejected"
            case .overlayClose: return "overlay.close"
            case .overlayResize: return "overlay.resize"
            case .overlayClosed: return "overlay.closed"
            case .pageRequest: return "page.request"
            case .pageRejected: return "page.rejected"
            case .pageClose: return "page.close"
            case .pageClosed: return "page.closed"
            case .pageCommand: return "page.command"
            case .pageState: return "page.state"
            case .pageResult: return "page.result"
            case .respawn: return "pane.respawn"
            case .linkClick: return "link.click"
            case .linkRefused: return "link.refused"
            case .pendingChunk: return "pending.chunk"
            case .pendingCommit: return "pending.commit"
            case .unknown(let kind): return kind
            }
        }
    }

    public var gen: Int
    public var rev: Int
    public var body: Body

    public init(gen: Int, rev: Int, body: Body) {
        self.gen = gen
        self.rev = rev
        self.body = body
    }
}

extension PresentationFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, gen, rev, hello, snapshot, status, context, info, layout, hud, notify, sound, ask, pick, overlay, page, respawn, link,
             pending
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gen = try container.decode(Int.self, forKey: .gen)
        rev = try container.decode(Int.self, forKey: .rev)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "hello": body = .hello(try container.decode(PresentationHello.self, forKey: .hello))
        case "ping": body = .ping
        case "ack": body = .ack
        case "snapshot": body = .snapshot(try container.decode(PresentationSnapshot.self, forKey: .snapshot))
        case "status": body = .status(try container.decodeIfPresent(PresentationStatus.self, forKey: .status))
        case "context": body = .context(try container.decodeIfPresent(String.self, forKey: .context))
        case "info": body = .info(try container.decodeIfPresent(PresentationInfo.self, forKey: .info))
        case "layout": body = .layout((try? container.decode(PresentationLayout.self, forKey: .layout)) ?? .invalid)
        case "hud": body = .hud(try container.decodeIfPresent(PresentationHud.self, forKey: .hud))
        case "notify": body = .notify(try container.decode(PresentationNotify.self, forKey: .notify))
        case "sound": body = .sound(try container.decode(PresentationSound.self, forKey: .sound))
        case "presenter.acquire": body = .presenterAcquire
        case "presenter.granted": body = .presenterGranted
        case "presenter.refused": body = .presenterRefused
        case "ask.request": body = .askRequest(try container.decode(PresentationAsk.self, forKey: .ask))
        case "ask.resolve": body = .askResolve(try container.decode(PresentationAskAnswer.self, forKey: .ask))
        case "ask.rejected": body = .askRejected(try container.decode(PresentationAskRef.self, forKey: .ask))
        case "ask.dismiss": body = .askDismiss(try container.decode(PresentationAskRef.self, forKey: .ask))
        case "pick.request": body = .pickRequest(try container.decode(PresentationPick.self, forKey: .pick))
        case "pick.resolve": body = .pickResolve(try container.decode(PresentationPickAnswer.self, forKey: .pick))
        case "pick.rejected": body = .pickRejected(try container.decode(PresentationPickRef.self, forKey: .pick))
        case "pick.dismiss": body = .pickDismiss(try container.decode(PresentationPickRef.self, forKey: .pick))
        case "overlay.request": body = .overlayRequest(try container.decode(PresentationOverlay.self, forKey: .overlay))
        case "overlay.rejected":
            body = .overlayRejected(try container.decode(PresentationOverlayChange.self, forKey: .overlay))
        case "overlay.close": body = .overlayClose(try container.decode(PresentationOverlayChange.self, forKey: .overlay))
        case "overlay.resize": body = .overlayResize(try container.decode(PresentationOverlayChange.self, forKey: .overlay))
        case "overlay.closed": body = .overlayClosed(try container.decode(PresentationOverlayChange.self, forKey: .overlay))
        case "page.request": body = .pageRequest(try container.decode(PresentationPage.self, forKey: .page))
        case "page.rejected": body = .pageRejected(try container.decode(PresentationPageChange.self, forKey: .page))
        case "page.close": body = .pageClose(try container.decode(PresentationPageChange.self, forKey: .page))
        case "page.closed": body = .pageClosed(try container.decode(PresentationPageChange.self, forKey: .page))
        case "page.command": body = .pageCommand(try container.decode(PresentationPageCommand.self, forKey: .page))
        case "page.state": body = .pageState(try container.decode(PresentationPageState.self, forKey: .page))
        case "page.result": body = .pageResult(try container.decode(PresentationPageResult.self, forKey: .page))
        case "pane.respawn": body = .respawn(try container.decode(PresentationRespawns.self, forKey: .respawn))
        case "link.click": body = .linkClick(try container.decode(PresentationLinkClick.self, forKey: .link))
        case "link.refused": body = .linkRefused(try container.decode(PresentationLinkRefusal.self, forKey: .link))
        case "pending.chunk": body = .pendingChunk(try container.decode(PresentationPendingChunk.self, forKey: .pending))
        case "pending.commit": body = .pendingCommit
        default: body = .unknown(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(body.kind, forKey: .kind)
        try container.encode(gen, forKey: .gen)
        try container.encode(rev, forKey: .rev)
        switch body {
        case .hello(let hello): try container.encode(hello, forKey: .hello)
        case .snapshot(let snapshot): try container.encode(snapshot, forKey: .snapshot)
        case .status(let status): try container.encodeIfPresent(status, forKey: .status)
        case .context(let context): try container.encodeIfPresent(context, forKey: .context)
        case .info(let info): try container.encodeIfPresent(info, forKey: .info)
        case .layout(let layout): try container.encode(layout, forKey: .layout)
        case .hud(let hud): try container.encodeIfPresent(hud, forKey: .hud)
        case .notify(let notify): try container.encode(notify, forKey: .notify)
        case .sound(let sound): try container.encode(sound, forKey: .sound)
        case .askRequest(let ask): try container.encode(ask, forKey: .ask)
        case .askResolve(let answer): try container.encode(answer, forKey: .ask)
        case .askRejected(let ref), .askDismiss(let ref): try container.encode(ref, forKey: .ask)
        case .pickRequest(let pick): try container.encode(pick, forKey: .pick)
        case .pickResolve(let answer): try container.encode(answer, forKey: .pick)
        case .pickRejected(let ref), .pickDismiss(let ref): try container.encode(ref, forKey: .pick)
        case .overlayRequest(let overlay): try container.encode(overlay, forKey: .overlay)
        case .overlayRejected(let change), .overlayClose(let change), .overlayResize(let change),
             .overlayClosed(let change):
            try container.encode(change, forKey: .overlay)
        case .pageRequest(let page): try container.encode(page, forKey: .page)
        case .pageRejected(let change), .pageClose(let change), .pageClosed(let change):
            try container.encode(change, forKey: .page)
        case .pageCommand(let command): try container.encode(command, forKey: .page)
        case .pageState(let state): try container.encode(state, forKey: .page)
        case .pageResult(let result): try container.encode(result, forKey: .page)
        case .respawn(let respawns): try container.encode(respawns, forKey: .respawn)
        case .linkClick(let click): try container.encode(click, forKey: .link)
        case .linkRefused(let refusal): try container.encode(refusal, forKey: .link)
        case .pendingChunk(let chunk): try container.encode(chunk, forKey: .pending)
        case .ping, .ack, .presenterAcquire, .presenterGranted, .presenterRefused, .unknown, .pendingCommit: break
        }
    }
}

/// PresentationCodec frames the stream as newline-delimited JSON, one frame per line.
public enum PresentationCodec {
    public enum FrameError: Error, Equatable {
        case oversize(Int)
        case malformed(String)
    }

    public static let version = 1
    /// A HUD body is the largest legitimate frame; this leaves it room and still bounds a hostile line.
    public static let maxFrameBytes = 256 * 1024
    /// Frames a subscriber may have queued before it counts as stalled.
    public static let maxPendingFrames = 256

    /// Encodes `frame` as one line, newline included.
    public static func encode(_ frame: PresentationFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(frame)
        guard line.count < maxFrameBytes else { throw FrameError.oversize(line.count) }
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// Decodes one line, without its newline.
    public static func decode(_ line: Data) throws -> PresentationFrame {
        guard line.count <= maxFrameBytes else { throw FrameError.oversize(line.count) }
        do {
            return try JSONDecoder().decode(PresentationFrame.self, from: line)
        } catch let error as DecodingError {
            throw FrameError.malformed(detail(error))
        } catch {
            throw FrameError.malformed(error.localizedDescription)
        }
    }

    /// The version both sides speak, or nil when the peer's is not a version at all.
    public static func negotiatedVersion(ours: Int, theirs: Int) -> Int? {
        guard ours >= 1, theirs >= 1 else { return nil }
        return min(ours, theirs)
    }

    private static func detail(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default: return "undecodable frame"
        }
    }
}
