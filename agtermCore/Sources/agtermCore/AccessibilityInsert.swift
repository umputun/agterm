/// Host-free routing decision for text an accessibility client hands to the terminal through
/// `AXValue` (`GhosttySurfaceView.setAccessibilityValue`, the dictation bridge).
///
/// The app-side setter has two destinations — the keyboard/IME `insertText` path for inline text, and
/// the bracketed-paste `insertPasted` path for anything carrying a line break, so an embedded newline
/// lands as literal text instead of typing Return and submitting the line. Only the *decision* lives
/// here; the two insert calls are AppKit/libghostty and stay in the app target.
public enum AccessibilityInsert {
    /// True when `text` carries a line break and must therefore take the bracketed-paste path.
    ///
    /// Uses `Character.isNewline`, NOT `text.contains("\n") || text.contains("\r")`. Swift's `String` is
    /// a collection of grapheme clusters and CRLF is a SINGLE cluster equal to neither `"\n"` nor
    /// `"\r"`, so the naive pair silently reports false for `"ls -la\r\n"` — and CRLF is exactly what a
    /// browser `<textarea>` value carries per the HTML spec, i.e. what a dictation client is likely to
    /// hand over. Missing it skipped the paste branch entirely (no bracketed-paste wrap at all), so the
    /// raw CR reached the pty, ICRNL mapped it to NL, and the line ran unconditionally.
    ///
    /// `isNewline` covers LF, CR, CRLF, VT, FF, NEL (U+0085), LS (U+2028) and PS (U+2029).
    public static func needsPasteRouting(_ text: String) -> Bool {
        text.contains(where: \.isNewline)
    }
}
