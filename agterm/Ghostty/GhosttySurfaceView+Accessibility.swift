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
/// `NSTextInputClient.insertText` path the physical keyboard and IME use; a set carrying ANY control
/// character — a line break (LF, CR or CRLF), TAB, ESC, NUL, DEL, or anything else in C0; see
/// `AccessibilityInsert.needsPasteRouting` — instead routes through the bracketed-paste path
/// (`insertPasted`), so a newline can't turn into Return and submit the line and a tab can't fire the
/// shell's completion. That is a bracketed-paste (mode 2004) guarantee, so it holds only against a program
/// that has 2004 on — the same caveat ⌘V and drop carry (see `setAccessibilityValue`).
///
/// Two deliberate scoping choices bound WHICH panes a non-dictation AX client sees. They do not bound
/// what it is TOLD about an exposed pane — see the screen-reader and replace-semantics limitations below,
/// both of which are real and accepted, not closed by the gating:
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
/// Known limitation (SCREEN READERS): because the value is not mirrored, an exposed pane reads to
/// VoiceOver as a text area named "Terminal" holding zero characters — it now announces an EMPTY editable
/// field where before this file the surface was absent from the tree and VO moved past it to the sidebar.
/// That is a real regression for VO users, traded knowingly for dictation working at all: the honest fix
/// is mirroring the grid (upstream ghostty 1.2's read-only integration, a much larger undertaking and the
/// better home for it), not narrowing the exposure, which would take dictation with it. Do not read the
/// gating above as covering this.
///
/// Known limitation (REPLACE SEMANTICS): a terminal is **append-at-cursor** — there is no addressable
/// document value to replace, so `accessibilityValue` reports empty and a set inserts at the cursor
/// rather than replacing. The value is still advertised settable because AX-based inserters require it.
/// A client that DIFFS its intended text against the field before writing therefore reads empty every
/// time and re-sends its whole hypothesis on each revision, concatenating it ("list", "list all", "list
/// all files" → `listlist alllist all files`). Incremental inserters (MacWhisper, and any client that
/// sends only the delta) are unaffected, which is the common case; a set-then-read-back-to-verify client
/// is not supported here. Closing this needs the same content mirroring the screen-reader case does.
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
    ///
    /// The `surface != nil` term covers the other end of the lifecycle: `createSurface` DEFERS creation
    /// while the backing size is still zero (`pendingSurfaceCreation`), and `acceptsFirstResponder` only
    /// checks `viewOnly`, so a pane in a window still being presented can be first responder with no
    /// libghostty surface behind it. Without the term it advertised a settable "Terminal" whose write
    /// `insertText`/`insertPasted` then dropped on their own `surface` guards — the first dictated phrase
    /// after opening a window vanishing with no feedback. Absent from the tree until the surface exists is
    /// the honest answer.
    private var axExposed: Bool { !viewOnly && deckVisible && surface != nil && window?.isVisible == true }

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
    /// set carrying any CONTROL character routes through `insertPasted` (bracketed paste), which — unlike
    /// `inject`'s newline→Return — treats the payload as literal text, so an embedded newline doesn't type
    /// Return and run the command and an embedded tab doesn't fire the shell's completion. The test is the
    /// host-free `AccessibilityInsert.needsPasteRouting` (unit-tested in `agtermCore`) and covers the whole
    /// C0 range plus DEL, not only line breaks; and it is NOT an inline `contains("\n") || contains("\r")`:
    /// CRLF is a single grapheme cluster equal to neither, so the naive pair misses `"\r\n"` — the line
    /// ending a browser `<textarea>` carries — and lets it through `insertText` unwrapped, where ICRNL runs
    /// the line.
    /// The literal-text guarantee tracks the program's bracketed-paste mode 2004, for the control
    /// characters exactly as for the newlines: a raw prompt with 2004 off still submits a trailing newline
    /// and still completes on a tab, exactly the caveat ⌘V and drop carry (see `insertPasted` /
    /// the libghostty note). Any in-flight IME/CJK composition is COMMITTED first on both branches (see
    /// `commitOrDiscardComposition`) — otherwise it either survives the AX insert and re-commits on the
    /// next keystroke, or is thrown away along with the characters the user already typed; the paste
    /// branch additionally `unmarkText()`s to clear libghostty's own preedit (`insertText` does that
    /// itself).
    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard axExposed, liveFocus else { return super.setAccessibilityValue(accessibilityValue) }
        let text = (accessibilityValue as? String) ?? (accessibilityValue as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        insertFromAccessibility(text)
    }

    /// Tell AX that this element's presence in the tree changed, because `axExposed` just flipped.
    ///
    /// A client resolves the "Terminal" element once and then keeps writing to it. Nothing in the AX
    /// contract makes it re-resolve on its own, so when the user switches sessions (or opens the
    /// dashboard, or minimizes the window) the pane it cached silently stops accepting writes: the
    /// setter's `axExposed, liveFocus` guard fails and falls through to `super.setAccessibilityValue`,
    /// which stores the string as an inert AX attribute and reports SUCCESS — the dictated sentence is
    /// lost with no error the client can see. `layoutChanged` is the notification for "the set of
    /// elements here changed"; posting it on the window makes a client re-resolve and land on the pane
    /// that is actually live.
    ///
    /// Driven off EVERY term of `axExposed`, not one flag taken to imply the rest — each of the four moves
    /// on its own at runtime:
    ///
    /// - `deckVisible` — its `didSet` (a session switch, an overlay covering the pane);
    /// - `viewOnly` — its `didSet` (the dashboard reparent; usually coincident with `deckVisible`, but not
    ///   assumed to be);
    /// - `surface != nil` — `createSurface` (creation is DEFERRED while the backing size is zero, so a pane
    ///   in a window still being presented has no surface yet) and `destroySurface`;
    /// - `window?.isVisible` — `viewDidMoveToWindow` plus the miniaturize/deminiaturize and app hide/unhide
    ///   observers (`observeWindowVisibilityChanges`), since `deckVisible` is pure MODEL state and a
    ///   minimized window leaves it `true`.
    ///
    /// `axPostedExposed` latches the last announced value, so the several call sites that can fire for one
    /// transition still post once, and a notification for another window costs a bool compare.
    ///
    /// `NSAccessibilityUIElementsKey` carries the element that changed, which is what the notification is
    /// documented to hold — an observer that reads it to decide what to re-resolve gets an answer instead
    /// of an empty payload it can treat as a no-op. Posted on the window while there is one; a surface
    /// already detached from its window falls back to the application element so the departure is still
    /// announced.
    func postAccessibilityExposureChange() {
        let exposed = axExposed
        guard exposed != axPostedExposed else { return }
        axPostedExposed = exposed
        let element: NSResponder = window ?? NSApplication.shared
        NSAccessibility.post(element: element, notification: .layoutChanged, userInfo: [.uiElements: [self]])
    }

    /// Tell AX the focused element moved, because `isAccessibilityFocused` (= `liveFocus`) just changed.
    ///
    /// The companion to `postAccessibilityExposureChange` for the FOCUS half: a client that anchors on
    /// `AXFocusedUIElement` (MacWhisper, system Dictation) needs to hear the focus leave one pane for
    /// another — a split-pane switch or a window key change moves it without any element appearing or
    /// disappearing.
    ///
    /// Called from BOTH focus routes, because there is no single funnel: `updateGhosttyFocus` covers the
    /// window-key observers and the (re)attach/reparent grabs, while `becomeFirstResponder` /
    /// `resignFirstResponder` deliberately bypass it and push `ghostty_surface_set_focus` themselves — and
    /// those two are the ORDINARY path (a click into the other split pane, a pane-switch binding), which
    /// moves focus without any window-key change at all. Wiring only the former left the common case
    /// announcing nothing while `axPostedFocus` stayed latched on the pane that had lost focus.
    ///
    /// The post is DEFERRED one run-loop turn for exactly that reason: inside the first-responder
    /// transitions AppKit has not yet updated `window.firstResponder`, so `liveFocus` reads stale there.
    /// The hop also coalesces — one focus move fires resign THEN become, and `axFocusPostScheduled` makes
    /// the pair evaluate once, after the responder has settled, so only the net result is announced.
    func postAccessibilityFocusChange() {
        guard !axFocusPostScheduled else { return }
        axFocusPostScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.axFocusPostScheduled = false
            self.emitAccessibilityFocusChange()
        }
    }

    /// Announce the settled focus state, on TRANSITIONS only (`axPostedFocus`).
    ///
    /// Both directions are announced. An earlier revision posted the GAIN only, on the theory that the
    /// losing pane's post would race the winner's — but the deferred, coalesced evaluation above removes
    /// that race outright, and gain-only silently dropped the case that has no winner: focus leaving the
    /// terminal for the sidebar, the dashboard, or another app. There the client kept its widget anchored
    /// to a pane that no longer accepts writes, and the next phrase fell through to
    /// `super.setAccessibilityValue`, which stores it as an inert attribute and reports success.
    ///
    /// Posted on the application element AND on the window. `kAXFocusedUIElementChangedNotification` is
    /// conventionally observed on the app element — an `AXObserver` registered there does not receive a
    /// window-posted notification — while the window post is what the paired `.layoutChanged` uses and is
    /// harmless to a client watching only one of the two (it re-resolves `AXFocusedUIElement` either way).
    /// Which one a given dictation client actually listens on is not determinable from here, so both go
    /// out rather than betting on one.
    private func emitAccessibilityFocusChange() {
        let focused = axExposed && liveFocus
        guard focused != axPostedFocus else { return }
        axPostedFocus = focused
        NSAccessibility.post(element: NSApplication.shared, notification: .focusedUIElementChanged)
        if let window { NSAccessibility.post(element: window, notification: .focusedUIElementChanged) }
    }

    /// The OTHER conventional AX insertion route: a client that reads `AXSelectedTextRange` and then sets
    /// `AXSelectedText` to the replacement, rather than setting `AXValue`. Both land in the same place.
    ///
    /// The selection this element reports is the empty range `{0, 0}`, so "replace the selection" IS
    /// "insert at the cursor" — the append-at-cursor contract the value setter already documents, with no
    /// second semantics to maintain. Advertised settable under the SAME first-responder gate as `AXValue`
    /// (see `isAccessibilitySelectorAllowed`) so an unfocused pane never claims a writability it would
    /// then drop. Without this, a client following the selected-text protocol found the attribute present
    /// but not settable and silently landed nothing, while the widget still anchored — the element looked
    /// editable and simply ate the dictation.
    override func setAccessibilitySelectedText(_ accessibilitySelectedText: String?) {
        guard axExposed, liveFocus else { return super.setAccessibilitySelectedText(accessibilitySelectedText) }
        guard let text = accessibilitySelectedText, !text.isEmpty else { return }
        insertFromAccessibility(text)
    }

    /// The shared AX insert: fire the input-side hooks `keyDown` fires, then route to the pty.
    ///
    /// Dictation IS typing, so it owes the same two side effects every keystroke has — without them a
    /// dictating user counts as idle (`onUserInput` is what resets the window's auto-follow timer, so
    /// auto-follow would yank the selection to a blocked session MID-sentence and deliver the rest of the
    /// text to the wrong terminal) and a session's stale agent-status glyph survives a dictated reply
    /// (`onUserInputClearsStatus`). `isInterrupt` is always false: an AX insert carries text, never the
    /// Escape/Ctrl-C keystroke that clears an ACTIVE glyph, so it clears blocked/completed only — the same
    /// answer `isInterruptKeystroke` gives for an ordinary printable key.
    private func insertFromAccessibility(_ text: String) {
        onUserInput?()
        onUserInputClearsStatus?(false)
        // ends any live composition BEFORE either branch. `insertPasted` commits for itself now, so the
        // paste branch's second call is a no-op against the `hasMarkedText()` guard; the `insertText`
        // branch has no commit of its own (it IS the commit path), so the call has to happen here.
        commitOrDiscardComposition()
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
        if selector == #selector(setAccessibilityValue(_:)) || selector == #selector(setAccessibilitySelectedText(_:)) {
            return axExposed && window?.firstResponder === self
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}
