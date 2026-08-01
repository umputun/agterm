import Foundation

/// Search keys for one palette row. Caller-supplied pickers match the label only, so a subtitle can carry
/// consequence text ("cannot be undone") without a refusal word isolating a destructive row. Built-in
/// palettes keep matching their subtitle, which carries the workspace and detail a user searches by.
public func paletteSearchKeys(title: String, subtitle: String?, callerSupplied: Bool) -> [String] {
    guard !callerSupplied, let subtitle else { return [title] }
    return [title, subtitle]
}
