// adapted from thdxg/macterm (MIT)

import agtermCore
import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    // MARK: - Drag and drop (issue #51)

    /// Accept the drag with a copy cursor when it carries something we can insert (a file/web URL or text),
    /// reject it otherwise — so a session-row drag from the sidebar (a private pasteboard type) is ignored.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropText(from: sender) != nil ? .copy : []
    }

    /// Insert the dropped file's path (shell-escaped, space-joined for multiple) or text at the cursor as a
    /// bracketed paste — the same no-auto-submit behavior as ⌘V, so a multi-line drop lands as literal text
    /// instead of executing each line. Deferred to the next runloop tick so the drag session fully unwinds
    /// before the terminal buffer is mutated.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = dropText(from: sender) else { return false }
        DispatchQueue.main.async { [weak self] in self?.insertPasted(text: text) }
        return true
    }

    /// The text a drop would insert, via the shared `GhosttyCallbacks.pasteboardText` reader; nil when the
    /// drag carries nothing usable (e.g. an internal sidebar row drag).
    private func dropText(from sender: any NSDraggingInfo) -> String? {
        GhosttyCallbacks.pasteboardText(sender.draggingPasteboard)
    }

    // MARK: - Keyboard

    private static let escapeKeyCode: UInt16 = 53

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }
        // every keystroke is user activity: reset the window's auto-follow idle timer UNCONDITIONALLY (not
        // gated on the status-clear below), else ordinary typing in an idle session wouldn't keep the idle
        // timer alive and the user would be yanked to a blocked session mid-type.
        onUserInput?()
        // a keystroke in a session flagged for your attention clears the glyph to idle: blocked/completed
        // on ANY key (you've engaged with the prompt / finished result), active ONLY on Escape — the
        // interrupt key — so ordinary typing while the agent works doesn't wipe the "working" glyph, but
        // cancelling a pending prompt (Esc) does. Esc-interrupt fires no Claude Code hook and a pending
        // prompt can still read active when you cancel (the blocked notification lands seconds later), so
        // this keystroke clear is the only signal that drops the stale glyph. fire it UNCONDITIONALLY with
        // the isEscape flag — the factory's closure owns the pane-scoped decision (AgentIndicator.clearedBy),
        // so the scratch (which has no view.session) self-clears too, and a background pane's block survives
        // foreground typing.
        onUserInputClearsStatus?(event.keyCode == Self.escapeKeyCode)
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option), !hasMarkedText() {
            var ke = buildKeyEvent(from: event, action: action)
            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            if text.isEmpty {
                ke.text = nil
                _ = ghostty_surface_key(surface, ke)
            } else {
                text.withCString { ptr in
                    ke.text = ptr
                    _ = ghostty_surface_key(surface, ke)
                }
            }
            return
        }

        if flags.contains(.command) {
            var ke = buildKeyEvent(from: event, action: action)
            ke.text = nil
            _ = ghostty_surface_key(surface, ke)
            return
        }

        let hadMarkedText = hasMarkedText()
        currentKeyEvent = event
        keyTextAccumulator = []
        let translationEvent = translatedEvent(for: event)
        interpretKeyEvents([translationEvent])
        currentKeyEvent = nil

        var ke = buildKeyEvent(from: event, action: action)
        ke.consumed_mods = consumedMods(translationEvent.modifierFlags)
        ke.composing = hasMarkedText() || hadMarkedText

        if !keyTextAccumulator.isEmpty {
            var commitKE = ke
            commitKE.composing = false
            for text in keyTextAccumulator {
                text.withCString { ptr in
                    commitKE.text = ptr
                    _ = ghostty_surface_key(surface, commitKE)
                }
            }
        } else if !hasMarkedText() {
            let text = filterSpecial(event.characters ?? "")
            if !text.isEmpty, !ke.composing {
                text.withCString { ptr in
                    ke.text = ptr
                    _ = ghostty_surface_key(surface, ke)
                }
            } else {
                ke.consumed_mods = GHOSTTY_MODS_NONE
                ke.text = nil
                _ = ghostty_surface_key(surface, ke)
            }
        }
    }

    override func doCommand(by _: Selector) {}

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var ke = buildKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        ke.text = nil
        _ = ghostty_surface_key(surface, ke)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        var ke = buildKeyEvent(from: event, action: isFlagPress(event) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        ke.text = nil
        _ = ghostty_surface_key(surface, ke)
    }

    // MARK: - Mouse

    private func mousePoint(from event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        return NSPoint(x: local.x, y: bounds.height - local.y)
    }

    /// Push the pointer position from `event` to libghostty and remember it in `lastReportedMousePoint`.
    /// Every handler that reports a position routes through here so `scrollWheel` can tell when the position
    /// is already current and skip a redundant `mouse_pos` (which a mouse-reporting TUI would otherwise turn
    /// into a per-packet synthetic motion report).
    private func reportMousePos(from event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        lastReportedMousePoint = pt
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        updateGhosttyFocus()
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    // forward right- and middle-button press/release to libghostty so its mouse bindings fire (e.g.
    // `right-click-action = paste`). mirrors the left handlers — `mouse_pos` before `mouse_button` — but
    // does NOT grab focus (a right/middle click on macOS doesn't move first responder). agterm has no
    // terminal context menu, so the return value is discarded like the left handler.
    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event))
    }

    // only the middle button (buttonNumber 2) maps to GHOSTTY_MOUSE_MIDDLE; any other extra button
    // (back/forward, etc.) falls through to the responder chain via super.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let surface else { super.otherMouseDown(with: event); return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let surface else { super.otherMouseUp(with: event); return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) { reportMousePos(from: event) }

    /// The pointer entered the surface: restore libghostty's mouse position from the current point, undoing
    /// `mouseExited`'s `-1, -1` reset so hovered-link and cursor-shape state are correct on re-entry.
    /// (`scrollWheel` also syncs `mouse_pos` when stale, so the first post-re-entry scroll no longer depends
    /// on this — but the restore still matters for hover/link state before any move.)
    override func mouseEntered(with event: NSEvent) { reportMousePos(from: event) }

    /// The pointer left the surface. Report negative coordinates so libghostty clears any hovered-link
    /// state — it drops `over_link`, reverts the mouse shape, and re-renders without the underline (see its
    /// `cursorPosCallback`). Without this a ⌘-hovered link stays highlighted after the mouse leaves the
    /// terminal (into the sidebar, another window, or off the edge) until ⌘ is released. Skipped mid-drag
    /// (a button is down) so a selection/drag that crosses the edge isn't reported at `-1, -1`.
    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, mods(event))
        lastReportedMousePoint = NSPoint(x: -1, y: -1)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        // sync libghostty's mouse position before scrolling, but ONLY when it's stale: mouse_scroll reports
        // at the last-known cell, and reactivating the window with no mouse move — cmd-tab/keyboard, or
        // scrolling to reactivate with the pointer already inside — delivers no mouseDown/mouseEntered, so
        // the position stays stale or -1,-1 (from mouseExited) and the first scroll inside a mouse-reporting
        // TUI (Claude Code, vim, less) reports at the wrong cell until you nudge the mouse. gating on
        // lastReportedMousePoint means an already-synced (normal) scroll doesn't re-push the same cell every
        // packet — which in an any-motion + sgr-pixel TUI would emit a synthetic motion report per packet.
        // (a LEFT click reactivation is already covered by mouseDown via acceptsFirstMouse; this handles the
        // no-click paths.)
        let pt = mousePoint(from: event)
        if pt != lastReportedMousePoint {
            ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
            lastReportedMousePoint = pt
        }
        var scrollMods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas { scrollMods |= 1 }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    // MARK: - Key event helpers

    private func buildKeyEvent(from event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var ke = ghostty_input_key_s()
        ke.action = action
        ke.keycode = UInt32(event.keyCode)
        ke.mods = mods(event)
        ke.consumed_mods = GHOSTTY_MODS_NONE
        ke.composing = false
        ke.text = nil
        ke.unshifted_codepoint = unshiftedCodepoint(from: event)
        return ke
    }

    private func consumedMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    private func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        let f = event.modifierFlags
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = f.rawValue
        let leftShift: UInt = 0x02, rightShift: UInt = 0x04
        let leftCtrl: UInt = 0x01, rightCtrl: UInt = 0x2000
        let leftAlt: UInt = 0x20, rightAlt: UInt = 0x40
        let leftCmd: UInt = 0x08, rightCmd: UInt = 0x10
        if raw & rightShift != 0, raw & leftShift == 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & rightCtrl != 0, raw & leftCtrl == 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & rightAlt != 0, raw & leftAlt == 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & rightCmd != 0, raw & leftCmd == 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    private func isFlagPress(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags
        switch event.keyCode {
        case 56, 60: return f.contains(.shift)
        case 58, 61: return f.contains(.option)
        case 59, 62: return f.contains(.control)
        case 55, 54: return f.contains(.command)
        case 57: return f.contains(.capsLock)
        default: return false
        }
    }

    private func filterSpecial(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "" }
        let v = scalar.value
        if v < 0x20 || (0xF700 ... 0xF8FF).contains(v) { return "" }
        return text
    }

    /// Builds a synthetic NSEvent whose modifier flags reflect libghostty's
    /// translation policy — with macos-option-as-alt on, Option is stripped so
    /// `characters(byApplyingModifiers:)` returns the unshifted char.
    private func translatedEvent(for event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let originalMods = mods(event)
        let translationModsRaw = ghostty_surface_key_translation_mods(surface, originalMods).rawValue
        var translationFlags = event.modifierFlags
        for (bit, flag) in [
            (GHOSTTY_MODS_SHIFT.rawValue, NSEvent.ModifierFlags.shift),
            (GHOSTTY_MODS_CTRL.rawValue, NSEvent.ModifierFlags.control),
            (GHOSTTY_MODS_ALT.rawValue, NSEvent.ModifierFlags.option),
            (GHOSTTY_MODS_SUPER.rawValue, NSEvent.ModifierFlags.command),
        ] {
            if translationModsRaw & bit != 0 { translationFlags.insert(flag) } else { translationFlags.remove(flag) }
        }
        if translationFlags == event.modifierFlags { return event }
        let translatedChars = event.characters(byApplyingModifiers: translationFlags) ?? ""
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translationFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: translatedChars,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first
        else { return 0 }
        return scalar.value
    }
}

// MARK: - NSTextInputClient

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange _: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        _markedRange = NSRange(location: NSNotFound, length: 0)
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
        if currentKeyEvent != nil {
            keyTextAccumulator.append(text)
        } else if let surface {
            text.withCString { ptr in
                var ke = ghostty_input_key_s()
                ke.action = GHOSTTY_ACTION_PRESS
                ke.text = ptr
                _ = ghostty_surface_key(surface, ke)
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange _: NSRange) {
        guard let surface else { return }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        _markedRange = text.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: text.count)
        _selectedRange = selectedRange
        text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.count)) }
    }

    func unmarkText() {
        guard let surface else { return }
        _markedRange = NSRange(location: NSNotFound, length: 0)
        ghostty_surface_preedit(surface, nil, 0)
    }

    func selectedRange() -> NSRange { _selectedRange }
    func markedRange() -> NSRange { _markedRange }
    func hasMarkedText() -> Bool { _markedRange.location != NSNotFound }

    func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .backgroundColor]
    }

    func characterIndex(for _: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewPt = NSPoint(x: x, y: bounds.height - y)
        let screenPt = window?.convertPoint(toScreen: convert(viewPt, to: nil)) ?? viewPt
        return NSRect(x: screenPt.x, y: screenPt.y - h, width: w, height: h)
    }

    // MARK: - Mouse cursor shape + link opening

    /// Applies the cursor shape libghostty requested (`GHOSTTY_ACTION_MOUSE_SHAPE`) — the pointing hand
    /// over a link, the I-beam over the grid, resize/crosshair/grab in the matching modes. No-ops when
    /// unchanged; otherwise invalidates the cursor rects so AppKit re-queries `resetCursorRects` and
    /// re-applies the cursor under the current pointer position (libghostty sends this as the mouse moves).
    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        guard shape != mouseShape else { return }
        mouseShape = shape
        window?.invalidateCursorRects(for: self)
    }

    /// AppKit cursor-rectangle hook: paint the whole surface with the libghostty-requested cursor.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.nsCursor(for: mouseShape))
    }

    /// Maps a libghostty mouse-shape to the closest AppKit `NSCursor`. Shapes without a system cursor
    /// (the zoom / diagonal-resize variants) fall back to the arrow.
    private static func nsCursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            return .resizeUpDown
        default: return .arrow
        }
    }

    /// Opens a URL from a link click (`GHOSTTY_ACTION_OPEN_URL`). The scheme allowlist lives in the
    /// host-free `LinkPolicy` (unit-tested); this is just the AppKit glue. Silently ignores a disallowed
    /// or unparseable link.
    func openLink(_ raw: String) {
        guard let url = LinkPolicy.permittedURL(from: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}
