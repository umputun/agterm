import Foundation

/// Renders an explicit `shell-integration-features` line from libghostty's resolved packed bits, so
/// ghostty stays the only thing that parses config text.
public enum ShellIntegrationFeatures {
    /// Flag names in the field order of libghostty's `ShellIntegrationFeatures`, so an index here is that
    /// flag's bit position. `ShellIntegrationFeatureBitsTests` pins the positions and the count.
    static let ordered = ["cursor", "sudo", "title", "ssh-env", "ssh-terminfo", "path"]

    /// Every flag spelled out from `resolvedBits`, with `disabled` forced off. Naming all of them is the
    /// point: ghostty re-parses this key from its defaults, so an omitted flag is reset, not left alone.
    public static func overrideValue(resolvedBits: UInt32, disabled: Set<String>) -> String {
        ordered.enumerated().map { index, name in
            let on = bits(resolvedBits, hasFlagAt: index) && !disabled.contains(name)
            return on ? name : "no-\(name)"
        }.joined(separator: ",")
    }

    static func bits(_ value: UInt32, hasFlagAt index: Int) -> Bool {
        value & (1 << UInt32(index)) != 0
    }
}
