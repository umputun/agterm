import Foundation

/// GhosttyConfigText reads ghostty config files the way libghostty's config-file reader does, for the keys
/// agterm resolves by hand because `ghostty_config_get` cannot return them.
public enum GhosttyConfigText {
    /// Setting is one config layer's final word on a key: never set, reset to the default by an empty value,
    /// or set to a parsed value.
    public enum Setting<T> {
        case unset
        case reset
        case value(T)

        /// over resolves this layer on top of `lower`, as ghostty replays the user config over the theme:
        /// a reset here drops the lower value, and only an unset key lets it through.
        public func over(_ lower: Setting<T>) -> T? {
            switch self {
            case .value(let value): return value
            case .reset: return nil
            case .unset:
                if case .value(let value) = lower { return value }
                return nil
            }
        }
    }

    /// keyValues parses config text into `key = value` pairs in file order, skipping blank and `#` lines and
    /// unquoting each value.
    public static func keyValues(in text: String) -> [(key: String, value: String)] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            return (key, unquoted(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
        }
    }

    /// unquoted strips one pair of surrounding double quotes, without unescaping.
    public static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// lastSetting folds every occurrence of `key` in order. A value `parse` rejects leaves the state as it
    /// was, since ghostty assigns a field only after its value parses.
    public static func lastSetting<T>(of key: String, in pairs: [(key: String, value: String)],
                                      parse: (String) -> T?) -> Setting<T> {
        pairs.reduce(Setting<T>.unset) { state, pair in
            guard pair.key == key else { return state }
            if pair.value.isEmpty { return .reset }
            return parse(pair.value).map(Setting.value) ?? state
        }
    }
}

extension GhosttyConfigText.Setting: Equatable where T: Equatable {}
extension GhosttyConfigText.Setting: Sendable where T: Sendable {}
