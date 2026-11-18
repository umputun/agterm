import Foundation

/// PresentationLinkClick is a path clicked in a pane the presenter shows, for the origin to open. `pane` is the
/// origin's identity of that pane. The mode decodes leniently, an unknown one as `overlay`, because a frame that
/// fails to decode closes the whole stream. `click` and `openers` ask for a snapshot instead of a page when the
/// resolved file matches one of the `open` selectors, and `snapshotOnly` forbids the page fallback for a viewer that
/// would hide it; all three decode as absent when malformed.
public struct PresentationLinkClick: Codable, Equatable, Sendable {
    public var raw: String
    public var pane: UUID
    public var mode: LinkOpenMode
    public var click: UUID?
    public var openers: [String]?
    public var snapshotOnly: Bool?

    private enum CodingKeys: String, CodingKey { case raw, pane, mode, click, openers, snapshotOnly }

    /// maxSelectors bounds the selectors a click may carry; each is a file name, so 255 bytes at most.
    public static let maxSelectors = 32

    public init(raw: String, pane: UUID, mode: LinkOpenMode, click: UUID? = nil, openers: [String]? = nil,
                snapshotOnly: Bool? = nil) {
        self.raw = raw
        self.pane = pane
        self.mode = mode
        self.click = click
        self.openers = openers
        self.snapshotOnly = snapshotOnly
    }

    /// selectors are the `open` selectors the click asks a snapshot for, empty without a click id. They are another
    /// host's text, so malformed ones are dropped.
    public var selectors: [OpenerSelector] {
        guard click != nil, let openers else { return [] }
        return openers.prefix(Self.maxSelectors).filter { $0.utf8.count <= 255 }.compactMap(OpenerSelector.parse)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        raw = try container.decode(String.self, forKey: .raw)
        pane = try container.decode(UUID.self, forKey: .pane)
        mode = (try? container.decode(String.self, forKey: .mode)).flatMap(LinkOpenMode.init(rawValue:)) ?? .overlay
        click = try? container.decodeIfPresent(UUID.self, forKey: .click)
        openers = try? container.decodeIfPresent([String].self, forKey: .openers)
        snapshotOnly = try? container.decodeIfPresent(Bool.self, forKey: .snapshotOnly)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(raw, forKey: .raw)
        try container.encode(pane, forKey: .pane)
        try container.encode(mode.rawValue, forKey: .mode)
        try container.encodeIfPresent(click, forKey: .click)
        try container.encodeIfPresent(openers, forKey: .openers)
        try container.encodeIfPresent(snapshotOnly, forKey: .snapshotOnly)
    }
}

/// PresentationLinkRefusal is the origin's answer to a forwarded click it did not open. An unknown reason decodes as
/// `notOpened`, for the same reason the click's mode decodes leniently. `click` names the click it answers when
/// that click carried one.
public struct PresentationLinkRefusal: Codable, Equatable, Sendable {
    public var reason: RemoteLinkRefusal
    public var click: UUID?

    private enum CodingKeys: String, CodingKey { case reason, click }

    public init(reason: RemoteLinkRefusal, click: UUID? = nil) {
        self.reason = reason
        self.click = click
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = (try? container.decode(String.self, forKey: .reason)).flatMap(RemoteLinkRefusal.init(rawValue:)) ?? .notOpened
        click = try? container.decodeIfPresent(UUID.self, forKey: .click)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason.rawValue, forKey: .reason)
        try container.encodeIfPresent(click, forKey: .click)
    }
}

/// PresentationLinkSnapshot answers a click whose resolved file an `open` selector matched: `token` claims one read of
/// that file through `session.overlay.page.serve`, `name` is its basename and `size` its length when offered.
public struct PresentationLinkSnapshot: Codable, Equatable, Sendable {
    public var click: UUID
    public var token: String
    public var name: String
    public var size: Int

    public init(click: UUID, token: String, name: String, size: Int) {
        self.click = click
        self.token = token
        self.name = name
        self.size = size
    }

    /// isAcceptable says whether the offer names a plain file this Mac's own page for that name could read, judged
    /// before any byte is fetched: the name and size are another host's word.
    public var isAcceptable: Bool {
        guard PasteBundle.isSafeComponent(name), let cap = LinkPolicy.previewBytes(forFileName: name) else { return false }
        return size >= 0 && size <= cap
    }
}
