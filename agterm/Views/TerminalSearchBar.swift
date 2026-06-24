import SwiftUI

/// A compact search bar shown over the focused terminal pane: a magnifier glyph, a query field, an
/// "N of M" counter, previous/next chevrons, and a close button. It is decoupled from `Session` — the
/// caller binds the needle, passes the display string, and the three navigation/close callbacks — so the
/// bar can be hosted at the `detailPane` level (like the floating overlay) without reaching into the model.
struct TerminalSearchBar: View {
    @Binding var needle: String
    let displayText: String
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    /// The terminal theme's foreground color for the chrome text + glyphs, so the bar tracks the theme.
    let chromeText: Color
    /// The terminal background color, used as the bar's opaque backing so it reads as a distinct panel.
    let terminalColor: Color

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(chromeText.opacity(0.7))
            TextField("Find", text: $needle)
                .textFieldStyle(.plain)
                .foregroundStyle(chromeText)
                // a fixed, compact field width so the bar stays a narrow right-aligned panel
                // instead of stretching across the top of the terminal.
                .frame(width: 150)
                .focused($fieldFocused)
                .onSubmit { onNext() }
                // Shift+Return steps to the previous match; a plain Return falls through to onSubmit (next).
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    onPrevious()
                    return .handled
                }
                .onKeyPress(.escape) { onClose(); return .handled }
                .accessibilityIdentifier("search-field")
            Text(displayText)
                .font(.caption)
                .foregroundStyle(chromeText.opacity(0.7))
                .accessibilityIdentifier("search-counter")
            chevron(systemName: "chevron.up", help: "Previous match", action: onPrevious)
            chevron(systemName: "chevron.down", help: "Next match", action: onNext)
            chevron(systemName: "xmark", help: "Close search", action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(terminalColor, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chromeText.opacity(0.18), lineWidth: 1))
        .shadow(radius: 8)
        .onAppear { fieldFocused = true }
    }

    /// A borderless chrome-tinted glyph button (the up/down/close controls), styled to the theme.
    private func chevron(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(chromeText.opacity(0.8))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
