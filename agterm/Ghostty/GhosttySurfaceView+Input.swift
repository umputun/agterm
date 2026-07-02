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
        // a keystroke in a session flagged for your attention clears the glyph to idle: blocked/completed
        // on ANY key (you've engaged with the prompt / finished result), active ONLY on Escape — the
        // interrupt key — so ordinary typing while the agent works doesn't wipe the "working" glyph, but
        // cancelling a pending prompt (Esc) does. Esc-interrupt fires no Claude Code hook and a pending
        // prompt can still read active when you cancel (the blocked notification lands seconds later), so
        // this keystroke clear is the only signal that drops the stale glyph. fires once: it goes to idle.
        if let status = session?.agentIndicator.status,
           status.clearedByKeystroke(isEscape: event.keyCode == Self.escapeKeyCode) {
            onUserInputClearsStatus?()
        }
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

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        updateGhosttyFocus()
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    // forward right- and middle-button press/release to libghostty so its mouse bindings fire (e.g.
    // `right-click-action = paste`). mirrors the left handlers — `mouse_pos` before `mouse_button` — but
    // does NOT grab focus (a right/middle click on macOS doesn't move first responder). agterm has no
    // terminal context menu, so the return value is discarded like the left handler.
    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event))
    }

    // only the middle button (buttonNumber 2) maps to GHOSTTY_MOUSE_MIDDLE; any other extra button
    // (back/forward, etc.) falls through to the responder chain via super.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let surface else { super.otherMouseDown(with: event); return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let surface else { super.otherMouseUp(with: event); return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
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
}
