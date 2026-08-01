// Accessibility bridge for voice dictation / assistive tools — original to agterm.
//
// Upstream ghostty (1.2) added a *read-only* AX integration that mirrors terminal content for screen
// readers and AI tools; it deliberately does not advertise an editable field, so it does not engage
// dictation (their voice-control issue is still open). This file takes the opposite, dictation-specific
// tack: it advertises the surface as an editable text area so hold-to-dictate widgets anchor to it, but
// gated to the on-screen pane(s) so it does not regress screen readers or expose background sessions
// (see the gating notes below). The WRITE path and the settable advertisement are additionally
// focus-gated (the read-only exposure is not).

import agtermCore
import AppKit

/// Exposes the Metal-backed terminal surface to the macOS Accessibility (AX) system as an
/// editable text area — but only for the pane(s) actually on screen. Exposure is NOT focus-gated
/// (a visible split exposes both panes); only the write path and the settable advertisement are.
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
/// `NSTextInputClient.insertText` path the physical keyboard and IME use; a set carrying ANY line break
/// (LF, CR or CRLF — see `AccessibilityInsert.needsPasteRouting`) instead routes through the
/// bracketed-paste path (`insertPasted`), so newlines can't turn into Return and submit commands (see
/// `setAccessibilityValue`).
///
/// Two deliberate scoping choices keep this from harming non-dictation AX clients:
///
/// - **Only the on-screen pane(s) are exposed** (`axExposed`, below). The deck eagerly realizes
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
/// design — the same flag drag/cursor use), so a split exposes TWO "Terminal" text areas. Only the
/// first-responder pane reports `isAccessibilityFocused`, advertises its value settable, and accepts a
/// write; the other reads as a non-settable text area. A client that anchors on `AXFocusedUIElement`
/// (MacWhisper, Dictation) targets the right pane; a client that enumerates by role/label sees the
/// unfocused pane is not settable and skips it. Accepted: only one pane can be the live text destination
/// at a time, and narrowing exposure to the focused pane would hide the other from screen readers.
///
/// One asymmetry follows from the settable gate being first-responder-only while the WRITE guard also
/// requires `isKeyWindow` (`liveFocus`): the first-responder pane of a visible-but-NOT-key window (a
/// second window while another holds key) advertises settable, yet its write is dropped because that
/// window isn't key. This is deliberate — settable must not flip to NO merely because agterm isn't key,
/// or a discovery-time probe would mis-cache it — and harmless in practice: a focus-anchoring dictation
/// client can't reach a non-key window (`AXFocusedUIElement` is nil when agterm isn't key), so only a
/// role/label-enumerating client hits it, the same class as the split case above.
///
/// Contract note: a terminal is **append-at-cursor** — there is no addressable document value to
/// replace, so `accessibilityValue` reports empty and a set inserts at the cursor rather than replacing.
/// The value is still advertised settable because AX-based inserters require it; a client that expects
/// full replace semantics (set-then-read-back-to-verify) is not supported here (dictation tools such as
/// MacWhisper insert incrementally and are unaffected).
extension GhosttySurfaceView {
    /// True only for the pane that is actually on screen: interactive (`!viewOnly`, so dashboard cells
    /// are excluded), the visible deck pane (`deckVisible`, so eagerly-realized background sessions
    /// and the hidden pane of an inactive split are excluded), AND in a window that is itself on screen
    /// (`window?.isVisible`). When false, `isAccessibilityElement` returns false and the text-area
    /// overrides fall through to `super`, so an off-screen surface is absent from the a11y tree exactly
    /// as before.
    ///
    /// The window term is load-bearing because `deckVisible` is pure MODEL state (`TerminalView` sets it
    /// from the deck's `deckInteractive && isActive && …`); nothing in it reads AppKit window state, so a
    /// MINIMIZED — or app-hidden — window leaves its pane `deckVisible == true`, and AppKit keeps
    /// miniaturized windows in the AX tree. Without this term such a pane kept advertising an editable
    /// "Terminal" text area to a role/label-enumerating client. `NSWindow.isVisible` is false exactly for
    /// the miniaturized/hidden/not-yet-ordered-in cases and true for a merely occluded or off-Space
    /// window, which is the wanted semantics. Exposure only — the write path was never reachable here,
    /// since `liveFocus` requires the key window.
    private var axExposed: Bool { !viewOnly && deckVisible && window?.isVisible == true }

    override func isAccessibilityElement() -> Bool { axExposed }

    override func accessibilityRole() -> NSAccessibility.Role? { axExposed ? .textArea : super.accessibilityRole() }

    override func accessibilityLabel() -> String? { axExposed ? "Terminal" : super.accessibilityLabel() }

    /// True while this surface holds first responder in the key window — the signal a dictation
    /// tool uses to confirm the terminal is the live text destination. Reuses `liveFocus`, the same
    /// key-window + first-responder predicate the cursor-focus path already owns.
    override func isAccessibilityFocused() -> Bool {
        guard axExposed else { return super.isAccessibilityFocused() }
        return liveFocus
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
    /// synthesised keystrokes) still lands text. Requires `liveFocus` (key window + first responder), so a
    /// client that enumerated the window's text areas or cached a focused element across a session switch
    /// can't inject into a background pane's pty. Inline text takes the keyboard/IME `insertText` path; a
    /// set carrying a line break routes through `insertPasted` (bracketed paste), which — unlike `inject`'s
    /// newline→Return — treats the payload as literal text, so embedded newlines don't type Return and run
    /// commands. The line-break test is the host-free `AccessibilityInsert.needsPasteRouting` (unit-tested
    /// in `agtermCore`), NOT an inline `contains("\n") || contains("\r")`: CRLF is a single grapheme
    /// cluster equal to neither, so the naive pair misses `"\r\n"` — the line ending a browser `<textarea>`
    /// carries — and lets it through `insertText` unwrapped, where ICRNL runs the line.
    /// The no-submit guarantee tracks the program's bracketed-paste mode 2004: a raw prompt with
    /// 2004 off still submits a trailing newline, exactly the caveat ⌘V and drop carry (see `insertPasted` /
    /// the libghostty note). `discardMarkedText()` first abandons any in-flight IME/CJK composition on both
    /// branches — otherwise a live marked-text composition survives the AX insert and re-commits on the
    /// next keystroke; the paste branch additionally `unmarkText()`s to clear libghostty's own preedit
    /// (`insertText` does that itself).
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard axExposed, liveFocus else { return super.setAccessibilityValue(accessibilityValue) }
        let text = (accessibilityValue as? String) ?? (accessibilityValue as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        inputContext?.discardMarkedText() // abandon any IME/CJK composition so it can't re-commit after the insert
        if AccessibilityInsert.needsPasteRouting(text) {
            unmarkText() // clear libghostty's preedit + _markedRange; the keyboard path's insertText does this itself
            insertPasted(text: text)
        } else {
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Advertise the value setter as settable (AXValueSettable = YES) so AX-based inserters attempt it —
    /// but ONLY on the first-responder pane, the one whose `setAccessibilityValue` will actually accept the
    /// write, so an exposed-but-unfocused pane (the other half of a split) doesn't claim writability and
    /// then silently drop. Gated on the first-responder term ONLY, NOT `liveFocus`: keying it on
    /// `isKeyWindow` too would flip settable to NO whenever agterm isn't key and break a client that probes
    /// settability at discovery time (before it activates agterm).
    ///
    /// The setter's answer is returned AUTHORITATIVELY (an explicit `false` off the first-responder pane),
    /// not delegated to `super`: this class implements both `accessibilityValue()` and
    /// `setAccessibilityValue(_:)`, and AppKit's default can report a getter/setter pair settable, which
    /// would leak AXValueSettable = YES onto the unfocused pane and defeat the gate.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) {
            return axExposed && window?.firstResponder === self
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}
