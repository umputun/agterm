import SwiftUI

/// Parent stacks probe every ZStack child at min, ideal and max sizes, hidden deck entries included.
/// The reader answers those probes itself and hands each terminal only the final size.
struct TerminalDeck<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ZStack { content }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .environment(\.terminalDeckTop, geometry.frame(in: .global).minY)
        }
    }
}

extension EnvironmentValues {
    /// terminalDeckTop is the deck's top edge in window space, where a plain session's terminal starts.
    @Entry var terminalDeckTop: CGFloat = 0
}

/// DeckPaneInset lays a deck pane out below `terminalDeckTop` instead of the native top safe area, which a
/// hidden deck entry's opacity-0 wrapper reports differently. A zero deck top keeps the native handling.
struct DeckPaneInset<Content: View>: View {
    @Environment(\.terminalDeckTop) private var deckTop
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            content
                .padding(.top, max(0, deckTop - proxy.frame(in: .global).minY))
        }
        .ignoresSafeArea(.container, edges: deckTop > 0 ? .top : [])
    }
}
