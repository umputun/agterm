import Foundation

/// TintColor is the fixed palette a sidebar tint picks from. The raw values are the wire and snapshot
/// spelling; the app maps each to the macOS system color of the same name so it follows light and dark.
public enum TintColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, blue, purple, gray, teal, pink, brown, indigo, mint

    /// validNamesList is the accepted spelling for help and rejection text, derived so it cannot go stale.
    public static var validNamesList: String { allCases.map(\.rawValue).joined(separator: "|") }
}

/// TintValue is a row tint's color: a palette name, or a `#rrggbb` hex the control API accepts. The raw
/// value is the wire and snapshot spelling, a name or a lowercase `#rrggbb`. A hex is fixed sRGB, so unlike
/// a name it does not follow light and dark.
public enum TintValue: Hashable, Sendable, RawRepresentable, Codable {
    case named(TintColor)
    case hex(String)

    /// init parses a name in any case, or a hex with or without `#`, normalized to lowercase `#rrggbb`.
    public init?(rawValue: String) {
        if let color = TintColor(rawValue: rawValue.lowercased()) {
            self = .named(color)
            return
        }
        guard WatermarkConfig.isValidColorHex(rawValue) else { return nil }
        self = .hex("#" + rawValue.drop { $0 == "#" }.lowercased())
    }

    public var rawValue: String {
        switch self {
        case let .named(color): color.rawValue
        case let .hex(hex): hex
        }
    }

    /// validValuesList is `validNamesList` plus the hex form, for rejection text.
    public static var validValuesList: String { TintColor.validNamesList + "|#rrggbb" }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = TintValue(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown tint color: \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// TintPart is a part of a sidebar row a tint can color.
public enum TintPart: String, CaseIterable, Codable, Sendable {
    case icon, name

    /// validNamesList is the accepted spelling for help and rejection text.
    public static var validNamesList: String { allCases.map(\.rawValue).joined(separator: ",") }
}

/// SidebarTint is a session or workspace row's tint: one color shown on one or more parts of the row.
/// `parts` is never empty and kept in `TintPart.allCases` order, so two tints showing the same thing are
/// equal however their parts were listed.
public struct SidebarTint: Equatable, Sendable {
    public let color: TintValue
    public let parts: [TintPart]

    /// init falls back to the icon when `parts` is empty, the one placement every tint must have.
    public init(color: TintValue, parts: Set<TintPart> = [.icon]) {
        self.color = color
        let ordered = TintPart.allCases.filter(parts.contains)
        self.parts = ordered.isEmpty ? [.icon] : ordered
    }

    /// init tints with a palette name.
    public init(color: TintColor, parts: Set<TintPart> = [.icon]) {
        self.init(color: .named(color), parts: parts)
    }

    /// shows reports whether the tint colors `part` of the row.
    public func shows(_ part: TintPart) -> Bool { parts.contains(part) }

    /// recolor is the tint a row with `current` gets for `color`: its own parts kept, an untinted row
    /// starting on the icon. A nil color clears.
    public static func recolor(_ current: SidebarTint?, to color: TintColor?) -> SidebarTint? {
        color.map { recolor(current, to: .named($0)) }
    }

    /// recolor is the named form's rule for any color value, with an untinted row starting on `placement`.
    public static func recolor(_ current: SidebarTint?, to color: TintValue, startingOn placement: Set<TintPart> = [.icon]) -> SidebarTint {
        SidebarTint(color: color, parts: current.map { Set($0.parts) } ?? placement)
    }

    /// place shows `current`'s color on `parts` instead. An untinted row stays untinted, so no row holds a
    /// placement it does not show.
    public static func place(_ current: SidebarTint?, on parts: Set<TintPart>) -> SidebarTint? {
        current.map { SidebarTint(color: $0.color, parts: parts) }
    }

    /// parseParts reads a wire placement list; nil when it is empty or names an unknown part.
    public static func parseParts(_ raw: [String]) -> Set<TintPart>? {
        let parts = raw.map { TintPart(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return Set(parts.compactMap { $0 })
    }
}

/// Snapshot encoding as `{"color": "red", "on": ["icon"]}`. Decoding is lossy like the snapshots around it:
/// an unknown color throws so the caller's `try?` drops the tint, while unknown parts are skipped and an
/// empty or missing list reads as the icon.
extension SidebarTint: Codable {
    enum CodingKeys: String, CodingKey {
        case color, on
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let color = try c.decode(TintValue.self, forKey: .color)
        let raw = (try? c.decodeIfPresent([String].self, forKey: .on)) ?? nil
        self.init(color: color, parts: Set((raw ?? []).compactMap(TintPart.init(rawValue:))))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(parts, forKey: .on)
    }
}
