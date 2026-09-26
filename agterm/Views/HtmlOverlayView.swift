import SwiftUI
import agtermCore

/// HtmlOverlayView is an HTML overlay's panel content: the page, under the toolbar with `--navigation` or
/// with only a floating close button without it. Every button goes through the same store and registry
/// paths as `session.overlay.reload` and `session.overlay.navigate`.
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
            if overlay.navigation { toolbar }
            HtmlWebViewHost(store: store, session: session, overlay: overlay, backgroundColor: backgroundColor,
                            isActive: isActive, visible: visible)
                .background(backgroundColor.flatMap { NSColor(agtermHex: $0) }.map { Color(nsColor: $0) } ?? background)
                .overlay {
                    if overlay.loadState == .failed { failure }
                }
                .overlay(alignment: .topTrailing) {
                    if !overlay.navigation {
                        // a fixed dark disc, so no page color can hide the only mouse exit
                        button("xmark", "Close", "htmlOverlay.close", enabled: true, tint: .white) {
                            store.closeHtmlOverlay(overlay.id)
                        }
                        .padding(6)
                        .background(Color.black.opacity(0.6), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .padding(8)
                    }
                }
        }
    }

    private var toolbar: some View {
        let registry = HtmlOverlayRegistry.shared
        return HStack(spacing: 10) {
            button("chevron.left", "Back", "htmlOverlay.back", enabled: overlay.current?.canGoBack == true) {
                _ = registry.navigate(overlay.id, .back)
            }
            button("chevron.right", "Forward", "htmlOverlay.forward", enabled: overlay.current?.canGoForward == true) {
                _ = registry.navigate(overlay.id, .forward)
            }
            button("arrow.clockwise", "Reload", "htmlOverlay.reload", enabled: true) {
                registry.reload(overlay.id, target: .current, store: store)
            }
            Text(overlay.current?.title ?? fallbackTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("htmlOverlay.title")
            button("safari", "Open in Browser", "htmlOverlay.browser", enabled: true) {
                _ = registry.navigate(overlay.id, .browser)
            }
            button("xmark", "Close", "htmlOverlay.close", enabled: true) {
                store.closeHtmlOverlay(overlay.id)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(background)
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

    private var fallbackTitle: String {
        switch overlay.source {
        case .file(let path, _):
            URL(fileURLWithPath: overlay.current?.page ?? path).lastPathComponent
        case .url(let url):
            overlay.current.flatMap { URL(string: $0.page)?.host } ?? url.host ?? url.absoluteString
        }
    }

    private func button(_ symbol: String, _ label: String, _ identifier: String, enabled: Bool, tint: Color? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(HtmlToolbarButtonStyle(tint: tint ?? foreground))
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
