extension ControlSessionNode {
    /// Keeps the pre-zmx initializer callable for agterm-linux, which may construct these nodes.
    /// Callers predating `backedByZmx` receive `nil`.
    public init(id: String, name: String, cwd: String, title: String? = nil, active: Bool, split: Bool,
                hasSplit: Bool? = nil, splitAxis: String? = nil,
                splitRatio: Double? = nil, splitFocused: Bool? = nil,
                overlay: Bool = false, overlaySizePercent: Int? = nil, paneOverlays: [String]? = nil,
                hud: ControlHudNode? = nil, scratch: Bool = false, flagged: Bool = false,
                commandWait: Bool? = nil,
                foreground: [String]? = nil, splitForeground: [String]? = nil,
                restoreCommand: String? = nil, splitRestoreCommand: String? = nil, status: String? = nil,
                statusPane: String? = nil, statusBlink: Bool? = nil, statusColor: String? = nil,
                statusShape: String? = nil, statusChangedAt: Double? = nil,
                background: BackgroundWatermark? = nil, unseen: Int? = nil,
                fontSize: Double? = nil, splitFontSize: Double? = nil, scratchFontSize: Double? = nil,
                surfaces: [ControlSurfaceNode]? = nil, realized: Bool? = nil) {
        self.init(id: id, name: name, cwd: cwd, title: title, active: active, split: split,
                  hasSplit: hasSplit, backedByZmx: nil, splitAxis: splitAxis,
                  splitRatio: splitRatio, splitFocused: splitFocused,
                  overlay: overlay, overlaySizePercent: overlaySizePercent, paneOverlays: paneOverlays,
                  hud: hud, scratch: scratch, flagged: flagged, commandWait: commandWait,
                  foreground: foreground, splitForeground: splitForeground,
                  restoreCommand: restoreCommand, splitRestoreCommand: splitRestoreCommand, status: status,
                  statusPane: statusPane, statusBlink: statusBlink, statusColor: statusColor,
                  statusShape: statusShape, statusChangedAt: statusChangedAt,
                  background: background, unseen: unseen, fontSize: fontSize,
                  splitFontSize: splitFontSize, scratchFontSize: scratchFontSize,
                  surfaces: surfaces, realized: realized)
    }
}
