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

struct AskDialogView: View {
    let ask: PendingAsk
    let anchorFrame: CGRect
    let font: NSFont
    let foreground: Color
    let background: Color
    let focusAllowed: Bool
    let onAnswer: (Int) -> Void
    let onDismiss: () -> Void
    @State private var navigation: AskNavigation
    @State private var focusRevision = 0

    init(ask: PendingAsk, anchorFrame: CGRect, font: NSFont, foreground: Color, background: Color,
         focusAllowed: Bool, onAnswer: @escaping (Int) -> Void, onDismiss: @escaping () -> Void) {
        self.ask = ask
        self.anchorFrame = anchorFrame
        self.font = font
        self.foreground = foreground
        self.background = background
        self.focusAllowed = focusAllowed
        self.onAnswer = onAnswer
        self.onDismiss = onDismiss
        _navigation = State(initialValue: AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID))
    }

    private var cell: CGFloat { max(8, font.pointSize * 0.6) }
    private var panelWidth: CGFloat { min(max(0, anchorFrame.width - 2 * cell), 72 * cell) }
    private var panelHeight: CGFloat { max(0, anchorFrame.height - 2 * cell) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { focusRevision += 1 }
            ScrollViewReader { reader in
                ViewThatFits(in: .vertical) {
                    content.fixedSize(horizontal: false, vertical: true)
                        .background(background)
                        .overlay { Rectangle().stroke(foreground.opacity(0.6), lineWidth: 1) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("ask-dialog")
                    ScrollView { content }
                        .background(background)
                        .overlay { Rectangle().stroke(foreground.opacity(0.6), lineWidth: 1) }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("ask-dialog")
                }
                .frame(width: panelWidth)
                .frame(maxHeight: panelHeight)
                .position(x: anchorFrame.midX, y: anchorFrame.midY)
                .onChange(of: navigation.highlighted, initial: true) { _, index in
                    guard let index else { return }
                    reader.scrollTo(ask.buttons[index].id)
                }
            }
            AskKeyCatcher(focusAllowed: focusAllowed, focusRevision: focusRevision, onKey: handle)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .font(Font(font))
        .foregroundStyle(foreground)
        .simultaneousGesture(TapGesture().onEnded { focusRevision += 1 })
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: cell * 1.5) {
            Text(verbatim: ask.title)
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ask-title")
            if let message = ask.message, !message.isEmpty {
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask-message")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: cell) {
                    ForEach(Array(ask.buttons.enumerated()), id: \.element.id) { index, choice in
                        button(choice, index: index).fixedSize()
                    }
                }
                VStack(alignment: .leading, spacing: cell) {
                    ForEach(Array(ask.buttons.enumerated()), id: \.element.id) { index, choice in
                        button(choice, index: index)
                    }
                }
            }
        }
        .padding(cell * 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ choice: ControlAskButton, index: Int) -> some View {
        Button { onAnswer(index) } label: {
            Text(Self.buttonLabel(choice, destructive: choice.id == ask.destructiveID))
                .fontWeight(choice.id == ask.destructiveID ? .bold : .regular)
                .padding(.horizontal, cell * 0.5)
                .padding(.vertical, cell * 0.4)
                .foregroundStyle(navigation.highlighted == index ? background : foreground)
                .background(navigation.highlighted == index ? foreground : Color.clear)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .id(choice.id)
        .accessibilityLabel(Text(verbatim: choice.label))
        .accessibilityValue(navigation.highlighted == index ? "selected" : "")
        .accessibilityIdentifier("ask-button-\(choice.id)")
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
        return AttributedString(destructive ? "[ ! " : "[ ") + label + AttributedString(" ]")
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

enum AskKey: Equatable {
    case forward, backward, activate, cancel
    case hotkey(String)
}

struct AskKeyCatcher: NSViewRepresentable {
    let focusAllowed: Bool
    let focusRevision: Int
    let onKey: (AskKey) -> Void

    func makeNSView(context _: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.focusAllowed = focusAllowed
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context _: Context) {
        _ = focusRevision
        nsView.focusAllowed = focusAllowed
        nsView.onKey = onKey
        nsView.grabFocus()
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
        var focusAllowed = false
        var onKey: ((AskKey) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            grabFocus()
        }

        func grabFocus() {
            guard focusAllowed, let window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if let key = AskKeyCatcher.key(for: event) { onKey?(key) }
        }
    }
}
