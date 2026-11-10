import agtermCore
import AppKit

/// SidebarInfoMetrics sizes a session row carrying an info line: the plain row on top, one smaller line under
/// it. The line lifts into the plain row's bottom padding by the density's `infoLineSpacing` and is padded by
/// the same amount under it, so the row grows by exactly one line.
enum SidebarInfoMetrics {
    static func font(base: Double) -> NSFont { .systemFont(ofSize: max(9, base - 1.5)) }

    static func lineHeight(base: Double) -> CGFloat {
        let font = font(base: base)
        return ceil(font.ascender - font.descender + font.leading)
    }

    static func rowHeight(base: Double, density: SidebarDensity) -> CGFloat {
        AppSettings.sidebarRowHeight(fontSize: base, density: density) + lineHeight(base: base)
    }
}

/// SidebarInfoCellView is a session cell with a styled info line under the name. Colors are rebuilt on every
/// `setColors`, so the selection and theme refresh paths recolor each fragment. On a selected row uncolored
/// fragments follow the selection foreground while colored ones keep their color, as a row tint does.
final class SidebarInfoCellView: SidebarCellView {
    let infoField = NSTextField(labelWithString: "")
    var titleBandHeight: NSLayoutConstraint?
    var infoTop: NSLayoutConstraint?
    private var spans: [SessionInfoSpan] = []
    private var base = AppSettings.defaultSidebarFontSize
    private var selected = false

    /// apply also resets both layout constants, since a reused cell keeps the density it was built with.
    func apply(spans: [SessionInfoSpan], base: Double, density: SidebarDensity) {
        self.spans = spans
        self.base = base
        titleBandHeight?.constant = AppSettings.sidebarRowHeight(fontSize: base, density: density)
        infoTop?.constant = -density.infoLineSpacing
        render()
    }

    override func setColors(selected: Bool) {
        super.setColors(selected: selected)
        self.selected = selected
        render()
    }

    override func layout() {
        super.layout()
        let available = infoField.cell?.titleRect(forBounds: infoField.bounds).width ?? infoField.bounds.width
        infoField.toolTip = infoField.attributedStringValue.size().width > available ? infoField.stringValue : nil
    }

    private func render() {
        let foreground = themeTextColor(selected: selected)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString()
        for span in spans {
            let font = font(for: span)
            let color = color(for: span, foreground: foreground)
            for (piece, emoji) in Self.emojiRuns(span.text) {
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
                if emoji {
                    let size = font.pointSize * Self.emojiScale
                    attributes[.font] = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
                    attributes[.baselineOffset] = font.capHeight / 2 - size * 0.375
                }
                text.append(NSAttributedString(string: piece, attributes: attributes))
            }
        }
        infoField.attributedStringValue = text
        needsLayout = true
    }

    // a color emoji glyph spans about -0.25em to 1em, so at the text's point size it reads oversized and low
    private static let emojiScale: CGFloat = 0.7

    /// emojiRuns splits text into consecutive runs of color-emoji and other characters. A text-default emoji
    /// (⚠, ✔, ⬆) counts only when followed by VS16, and VS15 keeps any character in its text form.
    private static func emojiRuns(_ text: String) -> [(String, Bool)] {
        var runs: [(String, Bool)] = []
        for character in text {
            let scalars = character.unicodeScalars
            let emoji = !scalars.contains("\u{FE0E}") && (scalars.first.map {
                $0.properties.isEmoji && ($0.properties.isEmojiPresentation || scalars.contains("\u{FE0F}"))
            } ?? false)
            if let last = runs.last, last.1 == emoji {
                runs[runs.count - 1].0.append(character)
                continue
            }
            runs.append((String(character), emoji))
        }
        return runs
    }

    private func font(for span: SessionInfoSpan) -> NSFont {
        let size = SidebarInfoMetrics.font(base: base).pointSize
        let weight: NSFont.Weight = span.bold ? .semibold : .regular
        let font = span.code ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        guard span.italic else { return font }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
    }

    private func color(for span: SessionInfoSpan, foreground: NSColor) -> NSColor {
        if let tint = span.color { return NSColor.tint(tint).withAlphaComponent(span.dim ? 0.55 : 1) }
        let alpha: CGFloat = selected ? (span.dim ? 0.6 : 0.85) : (span.dim ? 0.38 : 0.62)
        return foreground.withAlphaComponent(alpha)
    }
}
