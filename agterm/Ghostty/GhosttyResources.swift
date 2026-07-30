// adapted from thdxg/macterm (MIT)

import Foundation

/// Pure, side-effect-free selection of the ghostty resources directory for `GHOSTTY_RESOURCES_DIR` — only
/// which candidate dir wins; the `setenv`/`Bundle.main` side effects live in `GhosttyApp`, which feeds the
/// candidates and a filesystem probe in here.
///
/// agterm ships the ghostty resources in its bundle under `Contents/Resources/ghostty` (themes +
/// shell-integration), with the compiled terminfo DB at the sibling `Contents/Resources/terminfo` — the layout
/// a real Ghostty.app uses. libghostty reads shell-integration/themes from `GHOSTTY_RESOURCES_DIR` and derives
/// `TERMINFO` as `dirname(GHOSTTY_RESOURCES_DIR)/terminfo` at shell spawn, so pointing the env var at
/// `.../Resources/ghostty` resolves terminfo to `.../Resources/terminfo` automatically. Missing or incorrect
/// terminfo breaks key input and TERM=xterm-ghostty.
struct GhosttyResourceResolver {
    /// Candidate resource dirs, highest priority first.
    let candidates: [String]
    /// Filesystem existence probe. Injected so tests don't touch disk.
    let fileExists: (String) -> Bool

    /// Pick the first candidate containing `shell-integration/` (the marker that the ghostty resources are
    /// actually present). Nil when no candidate qualifies — the caller should then unset
    /// `GHOSTTY_RESOURCES_DIR`.
    func resolve() -> String? {
        candidates.first { fileExists($0 + "/shell-integration") }
    }
}
