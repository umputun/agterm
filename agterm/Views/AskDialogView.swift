import AppKit
import SwiftUI
import agtermCore

struct AskAnchorPreferences {
    var sessionID: UUID?
    var container: Anchor<CGRect>?
    var panes: [OverlayPane: Anchor<CGRect>] = [:]

    mutating func merge(_ other: AskAnchorPreferences) {
        guard let id = other.sessionID else { return }
        guard sessionID == id else { self = other; return }
        if let container = other.container { self.container = container }
        panes.merge(other.panes) { _, newest in newest }
    }
}

struct AskAnchorPreferenceKey: PreferenceKey {
    static let defaultValue = AskAnchorPreferences()

    static func reduce(value: inout AskAnchorPreferences, nextValue: () -> AskAnchorPreferences) {
        value.merge(nextValue())
    }
}

@MainActor
struct SessionAskInput {
    let session: Session
    let store: AppStore
    let actions: AppActions
    let windowID: UUID
    let askID: String
    let frame: CGRect?

    var visible: Bool {
        guard session.askPending?.id == askID, store.selectedSessionID == session.id,
              let frame, !frame.isEmpty,
              TerminalZoomRegistry.shared.controller(for: windowID)?.target == nil,
              DashboardControllerRegistry.shared.controller(for: windowID)?.isOpen != true else { return false }
        guard session.askPaneIdentity != nil else { return true }
        guard let pane = session.askTargetPane else { return false }
        return session.rendersPane(pane) && !session.scratchActive
    }

    var wantsFocus: Bool {
        guard visible, actions.library.activeWindowID == windowID,
              PickRegistry.shared.controller(for: windowID)?.modalPending != true,
              actions.palette?.mode == nil, !actions.renamePending,
              !actions.quickTerminal.holdsKey else { return false }
        guard let target = session.askTargetPane else { return true }
        return target == (session.splitFocused ? .right : .left)
    }

    func ownsInput(in window: NSWindow?, pane: OverlayPane? = nil) -> Bool {
        guard wantsFocus, let window, window.isKeyWindow,
              WindowRegistry.shared.windowID(for: window) == windowID,
              !(window.firstResponder is NSText) else { return false }
        return pane == nil || session.askTargetPane == nil || pane == session.askTargetPane
    }

    func blocksTerminalFocus(in window: NSWindow?, pane: OverlayPane?) -> Bool {
        guard visible else { return false }
        if actions.quickTerminal.holdsKey { return true }
        if actions.library.activeWindowID == windowID,
           actions.palette?.mode != nil || actions.renamePending || window?.firstResponder is NSText { return true }
        return ownsInput(in: window, pane: pane)
    }

    func selectPane() {
        guard visible, let pane = session.askTargetPane else { return }
        actions.setSplitFocus(pane == .right, of: session)
    }
}

struct SessionAskOverlay: View {
    let session: Session
    let store: AppStore
    let actions: AppActions
    let windowID: UUID
    let detailFrame: CGRect
    let paneFrames: HudPaneFrames
    let font: NSFont
    let foreground: Color
    let background: Color

    var body: some View {
        if let ask = session.askPending {
            let frame = coveredFrame
            let input = SessionAskInput(session: session, store: store, actions: actions,
                                        windowID: windowID, askID: ask.id, frame: frame)
            if let frame, input.visible {
                AskDialogView(ask: ask, anchorFrame: CGRect(origin: .zero, size: frame.size), font: font,
                              foreground: foreground, background: background, focusAllowed: input.wantsFocus,
                              sessionInput: input, onFocus: input.selectPane,
                              onAnswer: { index in
                                  let button = ask.buttons[index]
                                  session.resolveAsk(id: ask.id, ControlAskResult(result: .answered, id: button.id,
                                                                                label: button.label, index: index))
                              }, onDismiss: { session.resolveAsk(id: ask.id, ControlAskResult(result: .escaped)) })
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .position(x: frame.midX, y: frame.midY)
                    .id(ask.id)
            }
        }
    }

    var coveredFrame: CGRect? {
        guard session.askPaneIdentity != nil else { return detailFrame }
        return session.askTargetPane.flatMap { paneFrames[$0] }.map { CGRect($0) }
    }
}

extension GhosttySurfaceView {
    func deferMouseToAsk(with event: NSEvent) -> Bool {
        if Self.pickOwnsFocus(in: window) { return true }
        guard let owner = focusSession ?? session,
              let catcher = AskKeyCatcher.KeyCatcherView.sessionCatchers.object(forKey: owner.id as NSUUID),
              catcher.window === window, let input = catcher.sessionInput, input.visible else { return false }
        if input.actions.palette?.mode != nil || input.actions.renamePending || input.actions.quickTerminal.holdsKey { return true }
        if catcher.bounds.contains(catcher.convert(event.locationInWindow, from: nil)) {
            input.selectPane()
            catcher.grabFocus()
            return true
        }
        // a click on the program outside the dialog selects the uncovered pane, so the program keeps its keys
        if owner.overlaySurface as? GhosttySurfaceView === self, let target = owner.askTargetPane {
            owner.splitFocused = target == .left
        }
        return false
    }

    /// Hands a blocked terminal focus request to its visible session dialog.
    func deferFocusToAsk() -> Bool {
        guard askBlocksFocus else { return false }
        if let owner = focusSession ?? session {
            AskKeyCatcher.KeyCatcherView.sessionCatchers.object(forKey: owner.id as NSUUID)?.grabFocus()
        }
        return true
    }

    var askBlocksFocus: Bool {
        let owner = focusSession ?? session
        let pane: OverlayPane?
        if let owner, owner.surface as? GhosttySurfaceView === self || owner.leftOverlaySurface as? GhosttySurfaceView === self {
            pane = .left
        } else if let owner, owner.splitSurface as? GhosttySurfaceView === self || owner.rightOverlaySurface as? GhosttySurfaceView === self {
            pane = .right
        } else {
            pane = nil
        }
        return Self.pickOwnsFocus(in: window, session: owner, pane: pane)
    }
}

private struct AskButtonAnchors: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

struct AskDialogView: View {
    let ask: PendingAsk
    let anchorFrame: CGRect
    let font: NSFont
    let foreground: Color
    let background: Color
    let focusAllowed: Bool
    let sessionInput: SessionAskInput?
    let onFocus: () -> Void
    let onAnswer: (Int) -> Void
    let onDismiss: () -> Void
    @State private var navigation: AskNavigation
    @State private var focusRevision = 0
    @State private var buttonFrames: [CGRect] = []

    init(ask: PendingAsk, anchorFrame: CGRect, font: NSFont, foreground: Color, background: Color,
         focusAllowed: Bool, sessionInput: SessionAskInput? = nil, onFocus: @escaping () -> Void = {},
         onAnswer: @escaping (Int) -> Void, onDismiss: @escaping () -> Void) {
        self.ask = ask
        self.anchorFrame = anchorFrame
        self.font = font
        self.foreground = foreground
        self.background = background
        self.focusAllowed = focusAllowed
        self.sessionInput = sessionInput
        self.onFocus = onFocus
        self.onAnswer = onAnswer
        self.onDismiss = onDismiss
        _navigation = State(initialValue: AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID, destructiveID: ask.destructiveID))
    }

    private var terminalCell: CGFloat { max(8, font.pointSize * 0.6) }
    private var cell: CGFloat { ask.style == .gui ? 8 : terminalCell }
    private var buttonAlignment: Alignment {
        switch ask.align {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
    private var panelWidth: CGFloat {
        if let width = ask.width { return max(0, anchorFrame.width) * CGFloat(min(100, max(10, width))) / 100 }
        return min(max(0, anchorFrame.width * 0.9), 72 * terminalCell)
    }
    private var panelHeight: CGFloat { max(0, anchorFrame.height - 2 * cell) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
            ScrollViewReader { reader in
                ViewThatFits(in: .horizontal) {
                    if ask.width == nil {
                        panel.fixedSize(horizontal: true, vertical: false)
                    }
                    panel.frame(width: panelWidth)
                }
                .frame(maxWidth: panelWidth, maxHeight: panelHeight)
                .position(x: anchorFrame.midX, y: anchorFrame.midY)
                .onChange(of: navigation.highlighted, initial: true) { _, index in
                    guard let index else { return }
                    reader.scrollTo(ask.buttons[index].id)
                }
            }
            AskKeyCatcher(focusAllowed: focusAllowed, focusRevision: focusRevision, sessionInput: sessionInput, onKey: handle)
                .frame(width: sessionInput == nil ? 0 : anchorFrame.width, height: sessionInput == nil ? 0 : anchorFrame.height)
                .allowsHitTesting(false)
        }
        .font(ask.style == .gui ? .body : Font(font))
        .foregroundStyle(ask.style == .gui ? .primary : foreground)
        .overlayPreferenceValue(AskButtonAnchors.self) { anchors in
            GeometryReader { proxy in
                Color.clear.onChange(of: anchors.map { proxy[$0] }, initial: true) { _, frames in buttonFrames = frames }
            }
            .allowsHitTesting(false)
        }
        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
            guard !buttonFrames.contains(where: { $0.contains(tap.location) }) else { return }
            onFocus()
            focusRevision += 1
        })
    }

    private var panel: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
                .modifier(AskPanelStyle(style: ask.style, foreground: foreground, background: background))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ask-dialog")
            ScrollView { content }
                .modifier(AskPanelStyle(style: ask.style, foreground: foreground, background: background))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ask-dialog")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: cell * 1.5) {
            Text(verbatim: ask.title)
                .font(ask.style == .gui ? .headline : Font(font))
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ask-title")
            if let message = ask.message, !message.isEmpty {
                Text(verbatim: message)
                    .foregroundStyle(ask.style == .gui ? .secondary : foreground.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask-message")
            }
            ViewThatFits(in: .horizontal) {
                AskButtonLayout(axis: .horizontal, spacing: cell) {
                    ForEach(Array(ask.buttons.enumerated()), id: \.element.id) { index, choice in
                        button(choice, index: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: buttonAlignment)
                AskButtonLayout(axis: .vertical, spacing: cell) {
                    ForEach(Array(ask.buttons.enumerated()), id: \.element.id) { index, choice in
                        button(choice, index: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: buttonAlignment)
            }
        }
        .padding(cell * 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ choice: ControlAskButton, index: Int) -> some View {
        Group {
            if ask.style == .gui {
                guiButton(choice, index: index)
            } else {
                terminalButton(choice, index: index)
            }
        }
        .focusable(false)
        .id(choice.id)
        .accessibilityLabel(Text(verbatim: choice.label))
        .accessibilityValue(navigation.highlighted == index ? "selected" : "")
        .accessibilityIdentifier("ask-button-\(choice.id)")
        .anchorPreference(key: AskButtonAnchors.self, value: .bounds) { [$0] }
    }

    private func terminalButton(_ choice: ControlAskButton, index: Int) -> some View {
        Button { onAnswer(index) } label: {
            Text(Self.buttonLabel(choice, destructive: choice.id == ask.destructiveID))
                .fontWeight(choice.id == ask.destructiveID ? .bold : .regular)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, cell * 0.5)
                .padding(.vertical, cell * 0.4)
                .foregroundStyle(navigation.highlighted == index ? background : foreground)
                .background(navigation.highlighted == index ? foreground : foreground.opacity(0.12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func guiButton(_ choice: ControlAskButton, index: Int) -> some View {
        let button = Button(role: choice.id == ask.destructiveID ? .destructive : nil) {
            onAnswer(index)
        } label: {
            Text(Self.buttonLabel(choice, destructive: false))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .tint(choice.id == ask.destructiveID ? Color.red : Color.accentColor)
        if navigation.highlighted == index {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    static func buttonLabel(_ choice: ControlAskButton, destructive: Bool) -> AttributedString {
        var label = AttributedString(choice.label)
        if let hotkey = choice.hotkey {
            if let range = label.range(of: hotkey, options: .caseInsensitive) {
                label[range].underlineStyle = .single
            } else {
                var hint = AttributedString(hotkey.uppercased())
                hint.underlineStyle = .single
                label += AttributedString(" (") + hint + AttributedString(")")
            }
        }
        return destructive ? AttributedString("! ") + label : label
    }

    private func handle(_ key: AskKey) {
        switch key {
        case .forward: navigation.moveForward()
        case .backward: navigation.moveBackward()
        case .activate:
            if let index = navigation.activate() { onAnswer(index) }
        case .cancel: onDismiss()
        case .hotkey(let letter):
            if let index = navigation.hotkey(letter) { onAnswer(index) }
        }
    }
}

struct AskButtonLayout: Layout {
    let axis: Axis
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let sizes = sizes(proposal: proposal, subviews: subviews)
        let gaps = spacing * CGFloat(max(0, sizes.count - 1))
        if axis == .horizontal {
            return CGSize(width: sizes.reduce(0) { $0 + $1.width } + gaps, height: sizes.map(\.height).max() ?? 0)
        }
        return CGSize(width: sizes.first?.width ?? 0, height: sizes.reduce(0) { $0 + $1.height } + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let sizes = sizes(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        var offset: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            let point = axis == .horizontal
                ? CGPoint(x: bounds.minX + offset, y: bounds.midY - size.height / 2)
                : CGPoint(x: bounds.minX, y: bounds.minY + offset)
            subview.place(at: point, anchor: .topLeading, proposal: ProposedViewSize(size))
            offset += (axis == .horizontal ? size.width : size.height) + spacing
        }
    }

    private func sizes(proposal: ProposedViewSize, subviews: Subviews) -> [CGSize] {
        let width = Self.sharedWidth(natural: subviews.map { $0.sizeThatFits(.unspecified).width },
                                     proposal: proposal.width, axis: axis)
        return subviews.map {
            CGSize(width: width, height: $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        }
    }

    /// Every button takes the widest natural width; a column also caps it at the proposed width so a long
    /// label wraps instead of widening the panel.
    static func sharedWidth(natural: [CGFloat], proposal: CGFloat?, axis: Axis) -> CGFloat {
        let widest = natural.max() ?? 0
        return axis == .vertical ? min(widest, proposal ?? widest) : widest
    }
}

private struct AskPanelStyle: ViewModifier {
    let style: ControlAskStyle
    let foreground: Color
    let background: Color

    func body(content: Content) -> some View {
        content
            .background {
                if style == .gui { PalettePanelBackground() } else { background }
            }
            .clipShape(RoundedRectangle(cornerRadius: style == .gui ? 12 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: style == .gui ? 12 : 0)
                    .strokeBorder(style == .gui ? .white.opacity(0.1) : foreground.opacity(0.3))
            }
            .shadow(radius: style == .gui ? 24 : 0)
    }
}

enum AskKey: Equatable {
    case forward, backward, activate, cancel
    case hotkey(String)
}

struct AskKeyCatcher: NSViewRepresentable {
    let focusAllowed: Bool
    let focusRevision: Int
    var sessionInput: SessionAskInput?
    let onKey: (AskKey) -> Void

    func makeNSView(context _: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.focusAllowed = focusAllowed
        view.sessionInput = sessionInput
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context _: Context) {
        nsView.focusAllowed = focusAllowed
        nsView.sessionInput = sessionInput
        nsView.onKey = onKey
        nsView.updateFocus(revision: focusRevision)
    }

    static func dismantleNSView(_ nsView: KeyCatcherView, coordinator _: ()) {
        nsView.unregister()
    }

    static func key(for event: NSEvent) -> AskKey? {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        switch event.keyCode {
        case 48: return event.modifierFlags.contains(.shift) ? .backward : .forward
        case 124, 125: return .forward
        case 123, 126: return .backward
        case 36, 76: return .activate
        case 53: return .cancel
        default:
            guard let text = event.charactersIgnoringModifiers, text.utf8.count == 1,
                  let ascii = text.utf8.first, (65...90).contains(ascii) || (97...122).contains(ascii) else { return nil }
            return .hotkey(text.lowercased())
        }
    }

    final class KeyCatcherView: NSView {
        static let sessionCatchers = NSMapTable<NSUUID, KeyCatcherView>(keyOptions: .strongMemory, valueOptions: .weakMemory)
        var focusAllowed = false
        var sessionInput: SessionAskInput?
        var onKey: ((AskKey) -> Void)?
        private var previouslyAllowed = false
        private var lastRevision = 0

        var canFocus: Bool { sessionInput.map { $0.ownsInput(in: window) } ?? focusAllowed }

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObservingKeyWindow()
            if sessionInput != nil, let window {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: window)
                }
            }
            if window == nil { unregister() } else { updateFocus(revision: lastRevision) }
        }

        /// Window activation can change without invalidating the SwiftUI host.
        @objc private func windowKeyChanged(_: Notification) { updateFocus(revision: lastRevision) }

        private func stopObservingKeyWindow() {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.removeObserver(self, name: name, object: nil)
            }
        }

        func unregister() {
            stopObservingKeyWindow()
            releaseFocus()
            guard let input = sessionInput,
                  Self.sessionCatchers.object(forKey: input.session.id as NSUUID) === self else { return }
            Self.sessionCatchers.removeObject(forKey: input.session.id as NSUUID)
        }

        func updateFocus(revision: Int) {
            if let input = sessionInput, window != nil { Self.sessionCatchers.setObject(self, forKey: input.session.id as NSUUID) }
            let allowed = canFocus
            if allowed, sessionInput == nil || !previouslyAllowed || revision != lastRevision { grabFocus() }
            if !allowed { releaseFocus() }
            previouslyAllowed = allowed
            lastRevision = revision
        }

        private func releaseFocus() {
            guard let window, window.firstResponder === self else { return }
            window.makeFirstResponder(nil)
            guard let input = sessionInput, input.session.askPending == nil,
                  input.store.selectedSessionID == input.session.id,
                  input.actions.library.activeWindowID == input.windowID, window.isKeyWindow,
                  input.actions.palette?.mode == nil, !input.actions.renamePending,
                  !input.actions.quickTerminal.holdsKey,
                  let surface = input.session.topmostSurface as? GhosttySurfaceView, !surface.askBlocksFocus else { return }
            window.makeFirstResponder(surface)
        }

        func grabFocus() {
            guard canFocus, let window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard sessionInput == nil || canFocus else { return }
            if let key = AskKeyCatcher.key(for: event) { onKey?(key) }
        }
    }
}
