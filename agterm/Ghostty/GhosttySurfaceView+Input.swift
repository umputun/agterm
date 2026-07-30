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

    /// Insert the dropped path (shell-escaped, space-joined) or text at the cursor as a bracketed paste, so
    /// a multi-line drop is literal text, not executed lines. Deferred a tick so the drag session unwinds.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = dropText(from: sender) else { return false }
        DispatchQueue.main.async { [weak self] in self?.insertPasted(text: text) }
        return true
    }

    /// The text a drop would insert, via the shared `GhosttyCallbacks.pasteboardText` reader; nil when the
    /// drag carries nothing usable.
    private func dropText(from sender: any NSDraggingInfo) -> String? {
        GhosttyCallbacks.pasteboardText(sender.draggingPasteboard)
    }

    // MARK: - Keyboard

    /// Reduce an `NSEvent` to the host-free `InterruptKeystroke` classifier — Escape or a bare Ctrl-C.
    private func isInterruptKeystroke(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return InterruptKeystroke.isInterrupt(keyCode: event.keyCode,
                                              character: event.charactersIgnoringModifiers,
                                              modifiers: modifiers)
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }
        // every keystroke is user activity: reset the auto-follow idle timer UNCONDITIONALLY, not gated on
        // the status-clear below, else typing in an idle session yanks the user to a blocked one mid-type.
        onUserInput?()
        // a keystroke clears an attention glyph to idle: blocked/completed on ANY key, active ONLY on an
        // interrupt (Escape or Ctrl-C), so typing while the agent works keeps the "working" glyph but
        // cancelling a pending prompt drops it. Claude Code treats Ctrl-C like Esc for dismissing a prompt,
        // yet neither fires a hook and a cancelled prompt can still read active (its blocked notification
        // lands seconds later), so this is the only signal that drops the stale glyph. fire UNCONDITIONALLY
        // with the isInterrupt flag: the pane-scoped decision belongs to AgentIndicator.clearedBy, so the
        // scratch (no view.session) self-clears too and a background pane's block survives foreground typing.
        onUserInputClearsStatus?(isInterruptKeystroke(event))
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

    /// Push the pointer position to libghostty and remember it in `lastReportedMousePoint`. Every
    /// position-reporting handler routes through here so `scrollWheel` can skip a redundant `mouse_pos`.
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

    // forward right-/middle-button press/release so libghostty's mouse bindings fire (right-click-action),
    // in the left handlers' `mouse_pos`-then-`mouse_button` order minus the focus grab — these buttons
    // don't move first responder. no terminal context menu, so the return value is discarded.
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

    /// Re-assert the libghostty-requested cursor on every move: `cursorUpdate` fires only on tracking-area
    /// entry, and SwiftUI (which owns the hosted view's cursor) can reset it on any move, so without this
    /// the pointing hand reverts to the arrow along a link. Gated on `deckVisible` so a background deck
    /// surface never paints its shape over the visible terminal via the process-global cursor (issue #225),
    /// and on `ownsPointer` so it stops at the chrome drawn over this pane (issue #324). The position report
    /// stays ungated — libghostty tracks the pointer across the whole surface either way.
    override func mouseMoved(with event: NSEvent) {
        reportMousePos(from: event)
        guard deckVisible, ownsPointer(at: event.locationInWindow) else { return }
        Self.nsCursor(for: mouseShape).set()
    }

    /// Restore libghostty's mouse position on entry, undoing `mouseExited`'s `-1, -1` reset so hovered-link
    /// and cursor-shape state are right on re-entry — `scrollWheel`'s sync misses hover before any move.
    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        reportMousePos(from: event)
    }

    /// Report negative coordinates on exit so libghostty's `cursorPosCallback` clears hovered-link state
    /// (drops `over_link`, reverts the mouse shape, re-renders without the underline); without this a
    /// ⌘-hovered link stays highlighted after the mouse leaves the terminal until ⌘ is released. Skipped
    /// mid-drag (a button down) so a selection crossing the edge isn't reported at `-1, -1`.
    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        pointerInside = false
        ghostty_surface_mouse_pos(surface, -1, -1, mods(event))
        lastReportedMousePoint = NSPoint(x: -1, y: -1)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        // sync the mouse position before scrolling, but ONLY when stale: mouse_scroll reports at the
        // last-known cell, and a no-move reactivation (cmd-tab/keyboard, or scrolling with the pointer
        // already inside) delivers no mouseDown/mouseEntered, so the position stays stale or -1,-1 (from
        // mouseExited) and the first scroll in a mouse-reporting TUI hits the wrong cell. gating on
        // lastReportedMousePoint stops an already-synced scroll re-pushing the same cell per packet, which
        // an any-motion + sgr-pixel TUI turns into a synthetic motion report per packet. a LEFT-click
        // reactivation is already covered by mouseDown via acceptsFirstMouse.
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

    /// Builds a synthetic NSEvent whose modifier flags reflect libghostty's translation policy — with
    /// macos-option-as-alt on, Option is stripped so `characters(byApplyingModifiers:)` gives the unshifted char.
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
        // characters(byApplyingModifiers:) is valid only for key up/down; on a FlagsChanged (bare modifier)
        // event it raises an AppKit assertion. a modifier press carries no codepoint, so report 0 there.
        guard event.type == .keyDown || event.type == .keyUp,
              let chars = event.characters(byApplyingModifiers: []),
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

    /// Applies the cursor shape libghostty requested (`GHOSTTY_ACTION_MOUSE_SHAPE`). No-ops when unchanged,
    /// else sets the cursor at once, but only while this is the on-screen pane (`deckVisible`), the pointer
    /// is inside, and no chrome covers it (`ownsPointer`): a background deck surface must not paint its
    /// shape over the visible terminal (issue #225), a revert delivered after the pointer left (the I-beam
    /// libghostty emits once `mouseExited` reports `-1, -1`) must not paint the terminal cursor onto the
    /// sidebar, and a shape change arriving while the pointer rests on a divider must not repaint it
    /// (issue #324). Setting it here is what makes a stationary shape change (⌘ over a link without moving)
    /// take effect immediately.
    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        guard shape != mouseShape else { return }
        mouseShape = shape
        if deckVisible, pointerInside, ownsPointer() { Self.nsCursor(for: shape).set() }
    }

    /// AppKit's `.cursorUpdate` tracking-area callback (NOT cursor rectangles): paint the whole surface with
    /// the libghostty-requested cursor. SwiftUI (`TerminalView`) hosts the surface and owns the cursor,
    /// resetting it as the mouse moves, so `addCursorRect`/`resetCursorRects` never take hold here — the
    /// link still underlines (libghostty draws it) but the pointing hand is dropped; upstream Ghostty.app
    /// drives the cursor through SwiftUI for the same reason. Gated on `deckVisible`: AppKit still delivers
    /// a `cursorUpdate` to a hidden deck surface on window activation (issue #225 refocus), and on
    /// `ownsPointer` because entry can land in the band a divider's grab handle covers (issue #324).
    override func cursorUpdate(with event: NSEvent) {
        guard deckVisible, ownsPointer(at: event.locationInWindow) else { return }
        Self.nsCursor(for: mouseShape).set()
    }

    /// Re-assert this pane's cursor when its window becomes key: AppKit does NOT re-issue a `cursorUpdate`
    /// on bare activation, so a reactivating click leaves the OS arrow until the next move. Gated on
    /// `deckVisible` + `isKeyWindow` + pointer-in-bounds — read fresh from
    /// `mouseLocationOutsideOfEventStream`, since `pointerInside` can be stale on a no-move activation — so
    /// it never paints over the sidebar/titlebar or a background window, nor over a divider parked inside
    /// this pane's bounds (issue #324).
    func reassertCursorOnActivation() {
        guard deckVisible, let window, window.isKeyWindow else { return }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        guard bounds.contains(convert(pointInWindow, from: nil)), ownsPointer(at: pointInWindow) else { return }
        Self.nsCursor(for: mouseShape).set()
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

    /// Acts on a clicked terminal link (`GHOSTTY_ACTION_OPEN_URL`); the scheme/host decision lives in the
    /// host-free `LinkPolicy`. A `file://` link is REVEALED in Finder, never opened — reveal executes nothing.
    func openLink(_ raw: String) {
        switch LinkPolicy.disposition(for: raw) {
        case let .open(url): NSWorkspace.shared.open(url)
        case let .reveal(url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .ignore: return
        }
    }
}

// MARK: - Standard Edit menu (responder chain)

/// The stock Edit ▸ Copy/Paste/Select All actions, implemented on the surface so AppKit's automatic menu
/// enabling routes them to the terminal when it holds first responder, while a focused text field (inline
/// rename, palette search, Settings) keeps its own — its field editor wins the responder chain. That is why
/// agterm keeps the standard SwiftUI Edit menu instead of a custom Commands group. Each action runs the same
/// libghostty binding ⌘C/⌘V/⌘A use. Cut is deliberately NOT implemented, so it stays disabled for the
/// terminal yet works in text fields; it cannot be dropped on its own, sharing SwiftUI's `.pasteboard`
/// group. Undo/Redo are removed entirely (`CommandGroup(replacing: .undoRedo)` in `agtermApp+Menus`).
extension GhosttySurfaceView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) { performBindingAction("copy_to_clipboard") }

    @objc func paste(_ sender: Any?) { performBindingAction("paste_from_clipboard") }

    /// `override` because `selectAll(_:)` is declared on `NSResponder`, unlike `copy:`/`paste:`.
    override func selectAll(_ sender: Any?) { performBindingAction("select_all") }

    /// Gate the three items on real availability: Copy needs a selection, Paste something the paste path can
    /// insert, all three a realized surface (`performBindingAction` no-ops without one). Items we don't own
    /// enable by default — AppKit consults this only on the responder implementing the action, so `cut:`
    /// never reaches it.
    ///
    /// Paste asks `GhosttyCallbacks.hasPasteboardText()`, the SAME reader `paste_from_clipboard` uses,
    /// rather than probing for a plain string: the clipboard may hold a file/web URL with no string
    /// representation (a Finder copy) the reader turns into a shell-escaped path, so an `NSString` probe
    /// reports "nothing to paste" while ⌘V pastes it. A bare `canReadObject([NSURL])` TYPE probe is wrong
    /// the other way, enabling Paste for a URL-type-only pasteboard. The gate short-circuits on the first
    /// usable URL, never escaping a whole Finder copy to answer.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)):
            return surface != nil && GhosttyCallbacks.hasPasteboardText()
        case #selector(selectAll(_:)):
            return surface != nil
        default:
            return true
        }
    }
}
