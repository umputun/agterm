// adapted for agterm — accessibility bridge for voice dictation / assistive tools

import AppKit

/// Exposes the Metal-backed terminal surface to the macOS Accessibility (AX) system as an
/// editable text area.
///
/// The surface renders its own contents on the GPU and is otherwise deliberately absent from
/// the a11y tree (see `DashboardView` — "the Metal-backed surface is not in the a11y tree").
/// The side effect of that absence: assistive and voice tools — VoiceOver, the system
/// Dictation, and third-party dictation apps such as MacWhisper — probe `AXFocusedUIElement`
/// for a focused *text field* before they engage. Finding none over the terminal, they never
/// show their input widget or route text into it (in agterm the MacWhisper hold-to-dictate
/// widget simply never appears, while it does in every ordinary NSTextView/webview terminal).
///
/// This extension reports the minimal shape of an editable text field: role `.textArea`,
/// focusable, with a settable value routed into the existing `NSTextInputClient.insertText`
/// path — the very same path the physical keyboard and IME already use (see
/// `GhosttySurfaceView+Input.swift`). Tools that insert via `AXValue` land in `setAccessibilityValue`;
/// tools that synthesize keystrokes already flow through `keyDown`. Either way the keystrokes
/// reach libghostty unchanged.
///
/// We intentionally do NOT mirror live terminal contents into `accessibilityValue` (that would
/// pull VoiceOver into reading the whole GPU-rendered grid, a much larger undertaking). We only
/// need the element to *look* like a focused, editable text field so dictation engages — the
/// value it reads back is empty. `viewOnly` panes (non-interactive deck/preview surfaces) stay
/// out of the a11y tree exactly as before.
extension GhosttySurfaceView {
    override func isAccessibilityElement() -> Bool { !viewOnly }

    override func accessibilityRole() -> NSAccessibility.Role? { viewOnly ? super.accessibilityRole() : .textArea }

    override func accessibilityLabel() -> String? { viewOnly ? super.accessibilityLabel() : "Terminal" }

    /// True while this surface holds first responder in the key window — the signal a dictation
    /// tool uses to confirm the terminal is the live text destination.
    override func isAccessibilityFocused() -> Bool {
        guard !viewOnly else { return super.isAccessibilityFocused() }
        return window?.isKeyWindow == true && window?.firstResponder === self
    }

    // Report as an empty, editable text field. Enough for a dictation tool to recognise an
    // editable destination and anchor its widget; we don't surface the scrollback here.
    override func accessibilityValue() -> Any? { viewOnly ? super.accessibilityValue() : "" }
    override func accessibilityNumberOfCharacters() -> Int { viewOnly ? super.accessibilityNumberOfCharacters() : 0 }
    override func accessibilitySelectedText() -> String? { viewOnly ? super.accessibilitySelectedText() : "" }
    override func accessibilitySelectedTextRange() -> NSRange {
        viewOnly ? super.accessibilitySelectedTextRange() : NSRange(location: 0, length: 0)
    }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        viewOnly ? super.accessibilityVisibleCharacterRange() : NSRange(location: 0, length: 0)
    }
    override func accessibilityInsertionPointLineNumber() -> Int {
        viewOnly ? super.accessibilityInsertionPointLineNumber() : 0
    }

    /// Route an AX value/text set into the terminal via the same `insertText` the keyboard uses,
    /// so a tool that inserts through `AXValue` (rather than synthesised keystrokes) still lands text.
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard !viewOnly else { return super.setAccessibilityValue(accessibilityValue) }
        let text = (accessibilityValue as? String) ?? (accessibilityValue as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Advertise the value setter as settable (AXValueSettable = YES) so AX-based inserters attempt it.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if !viewOnly, selector == #selector(setAccessibilityValue(_:)) { return true }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}
