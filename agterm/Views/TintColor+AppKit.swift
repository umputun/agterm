import AppKit
import agtermCore

extension NSColor {
    /// tint maps a sidebar tint to the dynamic system color of the same name, so it follows light and dark.
    static func tint(_ color: TintColor) -> NSColor {
        switch color {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        case .teal: .systemTeal
        case .pink: .systemPink
        case .brown: .systemBrown
        case .indigo: .systemIndigo
        case .mint: .systemMint
        }
    }

    /// tint resolves a name as above and a hex to its fixed sRGB color.
    static func tint(_ value: TintValue) -> NSColor {
        switch value {
        case let .named(color): tint(color)
        case let .hex(hex): NSColor(agtermHex: hex) ?? .labelColor
        }
    }
}
