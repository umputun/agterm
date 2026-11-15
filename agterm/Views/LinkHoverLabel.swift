import SwiftUI

/// LinkHoverModel holds the hovered-link label of one terminal host. A surface writes into the model of the host
/// showing it now, so the label moves with the surface between the deck, zoom and the dashboard.
@MainActor @Observable
final class LinkHoverModel {
    var label: String?

    /// adopt makes this the model `view` writes into, clearing the one it leaves so no label outlives its host.
    func adopt(_ view: GhosttySurfaceView) {
        guard view.linkHover !== self else { return }
        view.linkHover?.label = nil
        view.linkHover = self
    }
}

/// LinkHoverModelKey carries a host's model to a layer above it that draws the label instead: a HUD panel is only
/// as tall as its message, so its label goes to the bottom-left of the pane the HUD floats over.
struct LinkHoverModelKey: PreferenceKey {
    static let defaultValue: LinkHoverModel? = nil

    static func reduce(value: inout LinkHoverModel?, nextValue: () -> LinkHoverModel?) {
        value = value ?? nextValue()
    }
}

struct LinkHoverLabel: View {
    let model: LinkHoverModel

    var body: some View {
        if let label = model.label {
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                .padding(6)
                .allowsHitTesting(false)
                .accessibilityIdentifier("link-hover")
        }
    }
}
