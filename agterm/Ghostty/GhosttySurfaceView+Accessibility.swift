// Accessibility bridge for voice dictation / assistive tools — original to agterm.
//
// Upstream ghostty (1.2) added a *read-only* AX integration that mirrors terminal content for screen
// readers and AI tools; it deliberately does not advertise an editable field, so it does not engage
// dictation (their voice-control issue is still open). This file takes the opposite, dictation-specific
// tack: it advertises the surface as an editable text area so hold-to-dictate widgets anchor to it, but
// gated to the single on-screen focused pane so it does not regress screen readers or expose background
// sessions (see the gating notes below).

import AppKit

/// Exposes the Metal-backed terminal surface to the macOS Accessibility (AX) system as an
/// editable text area — but only for the pane that is actually on screen and focused.
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
/// focusable, with a settable value. Tools that insert via `AXValue` land in `setAccessibilityValue`;
/// tools that synthesize keystrokes already flow through `keyDown`. Inline text goes through the same
/// `NSTextInputClient.insertText` path the physical keyboard and IME use; a multi-line set instead
/// routes through the bracketed-paste path (`insertPasted`), so newlines can't turn into Return and
/// submit commands (see `setAccessibilityValue`).
///
/// Two deliberate scoping choices keep this from harming non-dictation AX clients:
///
/// - **Only the on-screen focused pane is exposed** (`axExposed`, below). The deck eagerly realizes
///   every session's surface, so gating merely on `!viewOnly` would advertise one editable "Terminal"
///   per realized surface — N overlapping empty text areas over the visible one, and a writable AX
///   target for every *background* session. Gating on `deckVisible` (the same "on-screen pane, not
///   split-focus-gated" flag drag registration and cursor writes use) collapses that to at most the
///   visible pane(s); the write path additionally requires live focus.
///
/// - **We do NOT mirror live terminal contents into `accessibilityValue`** (that would pull VoiceOver
///   into reading the whole GPU-rendered grid, a much larger undertaking — and upstream's read-only
///   integration is the better home for that). The element only needs to *look* like a focused,
///   editable field so dictation engages; the value it reads back is empty.
///
/// Known limitation: `deckVisible` is not split-focus-gated (both panes of a visible split qualify, by
/// design — the same flag drag/cursor use), so a split advertises TWO "Terminal" text areas. Only the
/// first-responder pane reports `isAccessibilityFocused` and accepts a write; the other's setter falls
/// through to `super`. A client that anchors on `AXFocusedUIElement` (MacWhisper, Dictation) targets the
/// right pane; a client that instead enumerates by role/label could pick the unfocused pane and have its
/// write silently dropped. Accepted: only one pane can be the live text destination at a time, and
/// narrowing exposure to the focused pane would hide the other from screen readers and break the write
/// path whenever a non-activating dictation panel holds key focus.
///
/// Contract note: a terminal is **append-at-cursor** — there is no addressable document value to
/// replace, so `accessibilityValue` reports empty and a set inserts at the cursor rather than replacing.
/// The value is still advertised settable because AX-based inserters require it; a client that expects
/// full replace semantics (set-then-read-back-to-verify) is not supported here (dictation tools such as
/// MacWhisper insert incrementally and are unaffected).
extension GhosttySurfaceView {
    /// True only for the pane that is actually on screen: interactive (`!viewOnly`, so dashboard cells
    /// are excluded) AND the visible deck pane (`deckVisible`, so eagerly-realized background sessions
    /// and the hidden pane of an inactive split are excluded). Everything below falls through to `super`
    /// when this is false, restoring the pre-change a11y-tree absence for off-screen surfaces.
    private var axExposed: Bool { !viewOnly && deckVisible }

    override func isAccessibilityElement() -> Bool { axExposed }

    override func accessibilityRole() -> NSAccessibility.Role? { axExposed ? .textArea : super.accessibilityRole() }

    override func accessibilityLabel() -> String? { axExposed ? "Terminal" : super.accessibilityLabel() }

    /// True while this surface holds first responder in the key window — the signal a dictation
    /// tool uses to confirm the terminal is the live text destination.
    override func isAccessibilityFocused() -> Bool {
        guard axExposed else { return super.isAccessibilityFocused() }
        return window?.isKeyWindow == true && window?.firstResponder === self
    }

    // Report as an empty, editable text field. Enough for a dictation tool to recognise an
    // editable destination and anchor its widget; we don't surface the scrollback here.
    override func accessibilityValue() -> Any? { axExposed ? "" : super.accessibilityValue() }
    override func accessibilityNumberOfCharacters() -> Int { axExposed ? 0 : super.accessibilityNumberOfCharacters() }
    override func accessibilitySelectedText() -> String? { axExposed ? "" : super.accessibilitySelectedText() }
    override func accessibilitySelectedTextRange() -> NSRange {
        axExposed ? NSRange(location: 0, length: 0) : super.accessibilitySelectedTextRange()
    }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        axExposed ? NSRange(location: 0, length: 0) : super.accessibilityVisibleCharacterRange()
    }
    override func accessibilityInsertionPointLineNumber() -> Int {
        axExposed ? 0 : super.accessibilityInsertionPointLineNumber()
    }

    /// Route an AX value/text set into the terminal, so a tool that inserts through `AXValue` (rather than
    /// synthesised keystrokes) still lands text. Requires LIVE focus — the same predicate as
    /// `isAccessibilityFocused` (the shape the maintainer asked for) — so a client that enumerated the
    /// window's text areas or cached a focused element across a session switch can't inject into a
    /// background pane's pty. Inline text takes the keyboard/IME `insertText` path; a multi-line set routes
    /// through `insertPasted` (bracketed paste), which — unlike `inject`'s newline→Return — treats the
    /// payload as literal text, so embedded newlines don't type Return and run commands. The no-submit
    /// guarantee tracks the program's bracketed-paste mode 2004: a raw prompt with 2004 off still submits a
    /// trailing newline, exactly the caveat ⌘V and drop carry (see `insertPasted` / the libghostty note).
    /// `insertPasted` runs outside `keyDown`, so it does not clear an in-flight IME preedit the way
    /// `insertText` does; `unmarkText()` cancels any composition first so the paste can't duplicate it.
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard axExposed, window?.isKeyWindow == true, window?.firstResponder === self else {
            return super.setAccessibilityValue(accessibilityValue)
        }
        let text = (accessibilityValue as? String) ?? (accessibilityValue as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        if text.contains("\n") || text.contains("\r") {
            unmarkText() // insertText clears the preedit itself; the paste path must do it explicitly
            insertPasted(text: text)
        } else {
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Advertise the value setter as settable (AXValueSettable = YES) so AX-based inserters attempt it.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if axExposed, selector == #selector(setAccessibilityValue(_:)) { return true }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}
