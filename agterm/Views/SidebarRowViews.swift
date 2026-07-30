import agtermCore
import AppKit

/// An `NSTableCellView` with a leading icon, the name field, and a trailing badge. The icon is the inherited
/// `cell.imageView` (2x2 grid for a workspace, outlined terminal for a session), so AppKit re-tints it white on
/// a selected row; the name is `cell.textField`, which the rename and selection wiring drives.
final class SidebarCellView: NSTableCellView {
    /// Trailing unseen-notification count — a session's `unseenCount` or a collapsed workspace's roll-up; 0 hides.
    let badge = BadgeView()

    /// Agent-status glyph fed from the session's `agentIndicator`; hidden on `.idle` (workspace rows always idle).
    let statusIcon = StatusIconView()

    /// Inline "+" button between the name and the status icon, workspace cells only (nil for session cells).
    /// Set by the cell builder; `handleSingleClick` reads it to avoid toggling expansion on a click on it.
    var addButton: NSButton?

    /// Width of `addButton`, toggled between 0 and the glyph width by `setAddButtonVisible` — the
    /// collapse-the-slot convention of `StatusIconView.widthConstraint`, so an idle row's name reclaims it.
    var addButtonWidthConstraint: NSLayoutConstraint?

    private static let addButtonWidth: CGFloat = 16
    private var hoverTrackingArea: NSTrackingArea?

    /// Reveals or collapses the inline "+": the Finder/Xcode hover convention, so an idle row shows no button
    /// and the roll-up badge keeps its slot. Driven by `mouseEntered`/`mouseExited`, reset hidden when a reused
    /// cell is reconfigured. No-op for session cells.
    func setAddButtonVisible(_ visible: Bool) {
        guard let addButton, let addButtonWidthConstraint else { return }
        addButton.isHidden = !visible
        addButtonWidthConstraint.constant = visible ? Self.addButtonWidth : 0
    }

    // hover tracking for the "+" reveal, workspace cells only (session cells have no button to show)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea); self.hoverTrackingArea = nil }
        guard addButton != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // the "+" is a toggleable Interface element, gated at hover time only: a live Settings flip takes
        // effect on the next hover, and a "+" already on screen lingers until the next mouse exit/enter —
        // accepted for a hover-only affordance that clears on the next mouse move.
        guard !GhosttyApp.shared.hiddenInterfaceElements.contains(.workspaceAddSession) else { return }
        setAddButtonVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setAddButtonVisible(false)
    }

    /// Colors row text/icon from the terminal theme: a selected row takes the selection foreground (over the
    /// selection-background pill the row draws), or white over the soft wash when the theme exposes no
    /// selection color; an unselected row takes the theme foreground, icons dimmed. Driven from the real
    /// selection state, not `backgroundStyle` (AppKit flips that only while the table is first responder) —
    /// `SidebarRowView` re-asserts it on attach and on every selection flip, the coordinator on theme changes.
    func setColors(selected: Bool) {
        let app = GhosttyApp.shared
        let color = selected
            ? (app.terminalSelectionForegroundColor ?? .white)
            : (app.terminalForegroundColor ?? .labelColor)
        textField?.textColor = color
        let iconAlpha: CGFloat = selected ? 0.85 : 0.6
        imageView?.contentTintColor = color.withAlphaComponent(iconAlpha)
        addButton?.contentTintColor = color.withAlphaComponent(iconAlpha)
    }
}

/// A small filled accent capsule showing an unseen-notification count, custom-drawn (not an `NSTextField`) so
/// capsule and text center cleanly at row size. A single digit reads as a circle (min width = height). Exposed
/// to accessibility as a `notify-badge` static text.
final class BadgeView: NSView {
    /// The count to show, capped at `99+`. Drives `intrinsicContentSize` and redraw.
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityValue(label)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("notify-badge")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold)
    // leading-edge gap so the capsule keeps air from the status glyph to its left; a count-0 badge collapses
    // fully and lets that glyph sit flush.
    private static let leadingGap: CGFloat = 4
    private var textAttributes: [NSAttributedString.Key: Any] { [.font: Self.font, .foregroundColor: NSColor.white] }
    private var label: String { count > 99 ? "99+" : String(count) }

    override var intrinsicContentSize: NSSize {
        let height: CGFloat = 16
        // `isHidden` alone does NOT collapse a view in Auto Layout, so a count-0 badge would reserve a trailing
        // slot and push the status glyph in from the right edge; zero width lets the name reclaim it.
        guard count > 0 else { return NSSize(width: 0, height: height) }
        let capsule = max((label as NSString).size(withAttributes: textAttributes).width + 9, height)
        return NSSize(width: capsule + Self.leadingGap, height: height)
    }

    override func draw(_: NSRect) {
        let capsule = NSRect(x: Self.leadingGap, y: 0, width: bounds.width - Self.leadingGap, height: bounds.height)
        let radius = capsule.height / 2
        // systemRed (the conventional unread color) reads on dark rows and on the accent-colored selected row,
        // where an accent capsule would blend in.
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius).fill()
        let text = label as NSString
        let size = text.size(withAttributes: textAttributes)
        let origin = NSPoint(x: capsule.minX + (capsule.width - size.width) / 2, y: (capsule.height - size.height) / 2)
        text.draw(at: origin, withAttributes: textAttributes)
    }
}

/// A small SF-Symbol agent-status glyph left of the count badge: by default a `circle.fill` tinted
/// lavender-grey for `active`, amber for `blocked`, green for `completed`; a Settings shape or a per-call
/// `session.status --shape` swaps the silhouette, so shape carries the state alongside the tint. Hidden on
/// `.idle`. Accessibility: an `agent-status` static text whose value is the state name (XCUITest matches
/// `app.staticTexts["agent-status"]`; neither tint nor silhouette is observable there). Blink is a layer
/// `opacity` `CABasicAnimation` (autoreverse/repeat), added only while visible AND blinking.
final class StatusIconView: NSImageView {
    private static let blinkKey = "agent-status-blink"
    private static let glyphWidth: CGFloat = 16
    /// Symbol point size of the glyph; the Settings shape picker previews options at the same size, so an
    /// option looks like the glyph it installs.
    static let glyphPointSize: CGFloat = 13

    /// The view's width, collapsed to 0 on `.idle` so a status-less row reclaims the slot (its label truncates
    /// full-width); `glyphWidth` when a glyph shows. Activated in init, toggled in `apply`.
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("agent-status")
        widthConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    /// apply renders the indicator's tinted glyph and updates tooltip + accessibility value to the state name;
    /// `.idle` hides the view and stops the blink.
    func apply(_ indicator: AgentIndicator) {
        toolTip = indicator.status.tooltipText
        guard indicator.status != .idle else {
            isHidden = true
            image = nil
            widthConstraint.constant = 0
            setAccessibilityValue(AgentStatus.idle.rawValue)
            stopBlink()
            return
        }
        isHidden = false
        image = Self.icon(for: indicator.status, override: indicator.color, shape: indicator.shape)
        widthConstraint.constant = Self.glyphWidth
        setAccessibilityValue(indicator.status.rawValue)
        let shouldBlink = indicator.blink && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldBlink { startBlink() } else { stopBlink() }
    }

    private func startBlink() {
        guard layer?.animation(forKey: Self.blinkKey) == nil else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.2
        blink.duration = 0.5
        blink.autoreverses = true
        blink.repeatCount = .greatestFiniteMagnitude
        layer?.add(blink, forKey: Self.blinkKey)
    }

    private func stopBlink() {
        layer?.removeAnimation(forKey: Self.blinkKey)
    }

    private static func icon(for status: AgentStatus, override colorHex: String?, shape: StatusShape?) -> NSImage? {
        guard status != .idle else { return nil } // unreachable: `apply` returns early on `.idle` before drawing
        // symbol + color come from the shared resolvers, so this glyph and the SwiftUI StatusGlyph stay
        // identical, per-call `--shape`/`--color` overrides included.
        let config = NSImage.SymbolConfiguration(pointSize: Self.glyphPointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [GhosttyApp.shared.statusColor(for: status, override: colorHex)]))
        let symbol = GhosttyApp.shared.statusSymbolName(for: status, override: shape)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: status.rawValue)?
            .withSymbolConfiguration(config)
    }
}

/// Row view drawing its own selection pill in `drawBackground`, so the selection is the terminal's
/// `selection-background` color in every state. The table's `selectionHighlightStyle` is `.none` (`makeNSView`),
/// or AppKit paints a gray unemphasized fill whenever the sidebar isn't first responder (the normal case, since
/// focus lives in the terminal), overriding a custom `drawSelection`. `isEmphasized` is overridden so the row
/// redraws on a window key-state change (dimmer for a background window).
///
/// It is also the single source of truth for the cell's selection tint: `isSelected` (the state the pill draws
/// from) re-tints the hosted `SidebarCellView` whenever AppKit updates it, and `didAddSubview` tints a cell the
/// moment it attaches. Otherwise pill and text color desync — and on the many themes where
/// `foreground == selection-background` (the inverted-selection idiom), a stale tint renders the text invisible.
final class SidebarRowView: NSTableRowView {
    /// White-wash fallback opacity for themes with no selection color: brighter key, dimmer background.
    private static let keyAlpha: CGFloat = 0.13
    private static let inactiveAlpha: CGFloat = 0.07

    override var isEmphasized: Bool {
        get { window?.isKeyWindow ?? false }
        // isEmphasized is derived from the window's key state; the setter only triggers a redraw.
        // swiftlint:disable:next unused_setter_value
        set { needsDisplay = true }
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            // AppKit won't redraw with selectionHighlightStyle == .none; re-tint the cell from the pill's state.
            needsDisplay = true
            retintCellViews()
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // a cell materialized into an already-selected row (reload/expand row-map flux can make the cell
        // builder's own selection lookup miss) picks up the row's live state on attach.
        (subview as? SidebarCellView)?.setColors(selected: isSelected)
    }

    private func retintCellViews() {
        for case let cell as SidebarCellView in subviews { cell.setColors(selected: isSelected) }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isSelected else { return }
        if let selection = GhosttyApp.shared.terminalSelectionBackgroundColor {
            selection.withAlphaComponent(isEmphasized ? 1 : 0.55).setFill()
        } else {
            NSColor(white: 1, alpha: isEmphasized ? Self.keyAlpha : Self.inactiveAlpha).setFill()
        }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1.5), xRadius: 7, yRadius: 7).fill()
    }
}

/// A stable reference-type node fed to `NSOutlineView`, which keys item identity and expansion state by object
/// identity (`===`) — nodes must be the SAME instances across reloads, never fresh structs. The coordinator
/// caches one per workspace/session id and rebuilds only the child lists.
final class SidebarNode {
    enum Kind { case workspace, session }

    let kind: Kind
    let id: UUID
    /// Workspace child nodes, repopulated from the store on each rebuild. Empty for session nodes.
    var children: [SidebarNode] = []

    init(kind: Kind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}
