import Foundation

extension Session {
    /// The live HUD's size as one value, nil without a HUD.
    public var hudPanelSize: HudPanelSize? {
        guard hudActive, let width = overlaySizePercent, let height = hudHeightPercent else { return nil }
        return HudPanelSize(widthPercent: width, heightPercent: height, heightPoints: hudHeightPoints)
    }

    /// The spec the live panel is measured and painted from: its own, at the width an `overlay.resize`
    /// forced when one did. The stored spec keeps the caller's width, so a path reading that one would wrap
    /// and size a resized panel as if it had never been resized.
    public var effectiveHudSpec: HudSpec? {
        hudSpec.map { $0.withSizePercent(hudResizedWidthPercent ?? $0.sizePercent) }
    }
}
