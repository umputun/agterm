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
        }
    }
}
