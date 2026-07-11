import agtermCore
import AppKit

/// An `NSTableCellView` with a leading icon, the name field, and a trailing badge.
/// The icon is the inherited `cell.imageView` (a 2x2 grid glyph for a workspace, an outlined
/// terminal for a session), so AppKit re-tints it white on a selected row. The name field is `cell.textField`
/// (rename and selection wiring operate on it).
final class SidebarCellView: NSTableCellView {
    /// Trailing unseen-notification count for the row (a session's `unseenCount`, or a collapsed
    /// workspace's roll-up), drawn as a small accent capsule. Hidden when 0.
    let badge = BadgeView()

    /// Agent-status glyph drawn just left of the count badge, fed from the session's `agentIndicator`.
    /// Hidden on `.idle` (workspace rows always idle for now).
    let statusIcon = StatusIconView()

    /// Color the row text/icon from the terminal theme: a selected row pairs with the selection
    /// foreground (over the selection-background pill the row draws), or white over the soft wash when
    /// the theme exposes no selection color; an unselected row uses the theme foreground, icons dimmed.
    /// Driven from the real selection state (not `backgroundStyle`, which AppKit only flips while the
    /// table is first responder): the hosting `SidebarRowView` re-asserts it from its live `isSelected`
    /// on attach and on every selection flip, and the coordinator re-runs it on theme changes.
    func setColors(selected: Bool) {
        let app = GhosttyApp.shared
        let color = selected
            ? (app.terminalSelectionForegroundColor ?? .white)
            : (app.terminalForegroundColor ?? .labelColor)
        textField?.textColor = color
        imageView?.contentTintColor = color.withAlphaComponent(selected ? 0.85 : 0.6)
    }
}

/// A small filled accent capsule showing an unseen-notification count, custom-drawn (not an
/// `NSTextField`) so the capsule and text center cleanly at row size. A single digit reads as a
/// circle (min width = height). Exposed to accessibility as a `notify-badge` static text.
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
    // empty space reserved at the badge's LEADING edge, present only when the badge is shown, so the
    // capsule keeps air from the status glyph to its left — while a count-0 badge collapses fully and
    // lets that glyph sit flush at the trailing margin.
    private static let leadingGap: CGFloat = 4
    private var textAttributes: [NSAttributedString.Key: Any] { [.font: Self.font, .foregroundColor: NSColor.white] }
    private var label: String { count > 99 ? "99+" : String(count) }

    override var intrinsicContentSize: NSSize {
        let height: CGFloat = 16
        // collapse to zero width when there's nothing to show: `isHidden` alone does NOT collapse a
        // view in Auto Layout, so a count-0 badge would otherwise reserve a trailing slot and push the
        // status glyph in from the right edge. zero width lets the name reclaim it and the glyph sit flush.
        guard count > 0 else { return NSSize(width: 0, height: height) }
        let capsule = max((label as NSString).size(withAttributes: textAttributes).width + 9, height)
        return NSSize(width: capsule + Self.leadingGap, height: height)
    }

    override func draw(_: NSRect) {
        // the capsule occupies bounds minus the reserved leading gap; the status glyph to its left keeps air
        let capsule = NSRect(x: Self.leadingGap, y: 0, width: bounds.width - Self.leadingGap, height: bounds.height)
        let radius = capsule.height / 2
        // systemRed (the conventional unread/notification color) reads on both the dark rows and the
        // accent-colored selected row — an accent capsule would blend into a selected row.
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius).fill()
        let text = label as NSString
        let size = text.size(withAttributes: textAttributes)
        let origin = NSPoint(x: capsule.minX + (capsule.width - size.width) / 2, y: (capsule.height - size.height) / 2)
        text.draw(at: origin, withAttributes: textAttributes)
    }
}

/// A small SF-Symbol agent-status glyph drawn just left of the count badge: `active` is a blue
/// ellipsis, `blocked` an amber exclamation, `completed` a green check (all `.circle.fill` for a
/// consistent silhouette). Hidden on `.idle`. Exposed to accessibility as an `agent-status` static
/// text whose value is the state name (so XCUITest matches `app.staticTexts["agent-status"]`). Blink
/// is a layer `opacity` `CABasicAnimation` (autoreverse/repeat), added only while visible AND blinking.
final class StatusIconView: NSImageView {
    private static let blinkKey = "agent-status-blink"
    private static let glyphWidth: CGFloat = 16

    /// The view's width, collapsed to 0 on `.idle` so a status-less row reclaims the slot (and its
    /// label truncates full-width); `glyphWidth` when a glyph shows. Activated in init, toggled in `apply`.
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

    /// apply renders the indicator's tinted glyph (hiding the view and stopping any blink on `.idle`),
    /// updates the accessibility value to the state name, and starts/stops the blink animation.
    func apply(_ indicator: AgentIndicator) {
        guard indicator.status != .idle else {
            isHidden = true
            image = nil
            widthConstraint.constant = 0 // collapse the slot so the name reads full-width
            setAccessibilityValue(AgentStatus.idle.rawValue)
            stopBlink()
            return
        }
        isHidden = false
        image = Self.icon(for: indicator.status, override: indicator.color)
        widthConstraint.constant = Self.glyphWidth
        setAccessibilityValue(indicator.status.rawValue)
        if indicator.blink { startBlink() } else { stopBlink() }
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

    private static func icon(for status: AgentStatus, override colorHex: String?) -> NSImage? {
        guard status != .idle else { return nil } // unreachable: `apply` returns early on `.idle` before drawing
        // symbol + color come from the shared mapping (AgentStatus.symbolName + GhosttyApp.statusColor)
        // so this glyph and the SwiftUI StatusGlyph stay identical; a per-call `--color` overrides the tint.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [GhosttyApp.shared.statusColor(for: status, override: colorHex)]))
        return NSImage(systemSymbolName: status.symbolName, accessibilityDescription: status.rawValue)?
            .withSymbolConfiguration(config)
    }
}

/// Row view that draws its own selection pill in `drawBackground`, so the selection is the terminal's
/// `selection-background` color in every state. The table's `selectionHighlightStyle` is `.none` (set
/// in `makeNSView`), so AppKit draws nothing of its own — otherwise it paints a gray unemphasized fill
/// whenever the sidebar isn't first responder (the normal case, since focus lives in the terminal),
/// which would override a custom `drawSelection`. `isEmphasized` is overridden so the row redraws when
/// the window's key state changes (the brightness dims for a background window).
///
/// The row view is the single source of truth for the cell's selection tint: `isSelected` (the same
/// live state the pill draws from) re-tints the hosted `SidebarCellView` whenever AppKit updates it,
/// and `didAddSubview` tints a cell the moment it attaches. Without this, the pill (drawn live) and
/// the text color (applied imperatively at cell build) can desync — and on the many themes where
/// `foreground == selection-background` (the inverted-selection idiom), a stale tint renders the row
/// text fully invisible.
final class SidebarRowView: NSTableRowView {
    /// White-wash fallback opacity (themes with no selection color): brighter for the key window,
    /// dimmer for a background one.
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
            // the pill follows isSelected at draw time; re-tint the cell from the same state so the
            // text/icon can never keep the other state's color (white-on-white on inverted-selection
            // themes). AppKit won't redraw on its own with selectionHighlightStyle == .none.
            needsDisplay = true
            retintCellViews()
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // a cell materialized into an already-selected row (reload/expand row-map flux can make the
        // cell builder's own selection lookup miss) picks up the row's live state on attach.
        (subview as? SidebarCellView)?.setColors(selected: isSelected)
    }

    private func retintCellViews() {
        for case let cell as SidebarCellView in subviews { cell.setColors(selected: isSelected) }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isSelected else { return }
        if let selection = GhosttyApp.shared.terminalSelectionBackgroundColor {
            // the terminal's own selection color; dim it for a background (non-key) window.
            selection.withAlphaComponent(isEmphasized ? 1 : 0.55).setFill()
        } else {
            // no theme selection color: a soft white wash, brighter for the key window.
            NSColor(white: 1, alpha: isEmphasized ? Self.keyAlpha : Self.inactiveAlpha).setFill()
        }
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1.5), xRadius: 7, yRadius: 7).fill()
    }
}

/// A stable reference-type node fed to `NSOutlineView`. NSOutlineView keys item
/// identity and expansion state by object identity (`===`), so the nodes must be
/// the SAME instances across reloads — never freshly-allocated structs. The
/// coordinator caches one node per workspace/session id and reuses it, rebuilding
/// only the child lists from the store on each reload.
final class SidebarNode {
    enum Kind { case workspace, session }

    let kind: Kind
    let id: UUID
    /// Workspace child nodes, repopulated from the store on each rebuild. Empty
    /// for session nodes.
    var children: [SidebarNode] = []

    init(kind: Kind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}
