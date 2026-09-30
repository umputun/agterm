import SwiftUI
import agtermCore

/// HtmlOverlayView is an HTML overlay's panel content: the page under an app-drawn strip naming its source,
/// which the page cannot cover, with navigation buttons for `--navigation`; a chromeless page has no strip.
struct HtmlOverlayView: View {
    let store: AppStore
    let session: Session
    let overlay: HtmlOverlay
    /// backgroundColor is the overlay's `--background-color`; nil keeps the theme background.
    let backgroundColor: String?
    /// isActive lets the page take first responder when it mounts; false for a background session or an
    /// unfocused pane, which must not steal the keyboard.
    let isActive: Bool
    /// visible is whether the page is on screen, which decides drop registration apart from focus.
    let visible: Bool
    let foreground: Color
    let background: Color

    var body: some View {
        VStack(spacing: 0) {
            if !overlay.chromeless {
                strip
                Rectangle().fill(foreground.opacity(0.1)).frame(height: 1)
            }
            HtmlWebViewHost(store: store, session: session, overlay: overlay, backgroundColor: backgroundColor,
                            isActive: isActive, visible: visible)
                .background(backgroundColor.flatMap { NSColor(agtermHex: $0) }.map { Color(nsColor: $0) } ?? background)
                .overlay {
                    if overlay.loadState == .failed { failure }
                }
        }
    }

    private var strip: some View {
        let registry = HtmlOverlayRegistry.shared
        return HStack(spacing: 10) {
            if overlay.navigation {
                button("chevron.left", "Back", "htmlOverlay.back", enabled: overlay.current?.canGoBack == true) {
                    _ = registry.navigate(overlay.id, .back)
                }
                button("chevron.right", "Forward", "htmlOverlay.forward", enabled: overlay.current?.canGoForward == true) {
                    _ = registry.navigate(overlay.id, .forward)
                }
                button("arrow.clockwise", "Reload", "htmlOverlay.reload", enabled: true) {
                    registry.reload(overlay.id, target: .current, store: store)
                }
            }
            label
            if overlay.navigation {
                button("safari", "Open in Browser", "htmlOverlay.browser", enabled: true) {
                    _ = registry.navigate(overlay.id, .browser)
                }
                switch overlay.source {
                case .file:
                    button("arrow.up.forward.app", "Show in Finder", "htmlOverlay.finder", enabled: true) {
                        _ = registry.navigate(overlay.id, .finder)
                    }
                case .url:
                    button("link", "Copy Link", "htmlOverlay.copy", enabled: true) {
                        registry.copyLink(overlay.id)
                    }
                }
            }
            button("xmark", "Close", "htmlOverlay.close", enabled: true) {
                store.closeHtmlOverlay(overlay.id)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(foreground.opacity(0.06))
        .background(background)
    }

    // the title is the page's own text, so it stays a separate dimmed view that gives up width before the
    // source does and cannot pass for part of the app-drawn identity
    private var label: some View {
        HStack(spacing: 6) {
            Text(overlay.identity)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(overlay.current?.page ?? sourceText)
                .accessibilityIdentifier("htmlOverlay.identity")
            if let title = overlay.current?.title {
                Text("·")
                    .foregroundStyle(foreground.opacity(0.4))
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(foreground.opacity(0.55))
                    .help(title)
                    .accessibilityIdentifier("htmlOverlay.title")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // over the page so a failed load never reads as a blank one; reload replaces it with the loading state
    private var failure: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
            Text("The page could not be loaded")
                .font(.headline)
            if let error = overlay.loadError {
                Text(error)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(foreground)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor.flatMap { NSColor(agtermHex: $0) }.map { Color(nsColor: $0) } ?? background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("htmlOverlay.error")
    }

    private var sourceText: String {
        switch overlay.source {
        case .file(let path, _): path
        case .url(let url): url.absoluteString
        }
    }

    private func button(_ symbol: String, _ label: String, _ identifier: String, enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(HtmlToolbarButtonStyle(tint: foreground))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// HtmlToolbarButtonStyle draws the page panel's buttons in the theme's text color, which a plain borderless
/// style would keep at full strength whether disabled or pressed: it dims a disabled button, darkens a pressed
/// one and marks the hovered one.
private struct HtmlToolbarButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HtmlToolbarButton(configuration: configuration, tint: tint)
    }
}

private struct HtmlToolbarButton: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(tint.opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.3))
            .frame(width: 22, height: 20)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(configuration.isPressed ? 0.22 : hovered && isEnabled ? 0.1 : 0)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// HtmlWebViewHost mounts the registry's web view for a page. Like `TerminalView` it never owns the view:
/// dismantling is a no-op, so the page survives remounts and only `HtmlOverlayRegistry.release` ends it.
struct HtmlWebViewHost: NSViewRepresentable {
    let store: AppStore
    let session: Session
    let overlay: HtmlOverlay
    let backgroundColor: String?
    let isActive: Bool
    let visible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context _: Context) -> HtmlOverlayWebView {
        HtmlOverlayRegistry.shared.page(for: overlay, store: store, backgroundColor: backgroundColor).webView
    }

    func updateNSView(_ view: HtmlOverlayWebView, context: Context) {
        HtmlOverlayRegistry.shared.existing(overlay.id)?.apply(overlay)
        view.setDropsEnabled(visible)
        HtmlOverlayRegistry.shared.existing(overlay.id)?.setOnScreen(visible)
        guard isActive else {
            context.coordinator.didFocus = false
            if view.holdsFocus { view.window?.makeFirstResponder(nil) }
            return
        }
        // focus once per activation and never over a text field editor, as `TerminalView.focusIfNeeded` does
        guard let window = view.window, !context.coordinator.didFocus, !view.holdsFocus,
              !(window.firstResponder is NSText), !view.deferFocusToAsk(in: session) else { return }
        context.coordinator.didFocus = true
        window.makeFirstResponder(view)
    }

    static func dismantleNSView(_: HtmlOverlayWebView, coordinator _: Coordinator) {}

    final class Coordinator {
        var didFocus = false
    }
}
