import AppKit
import ObjectiveC

/// SplitCursorRects turns AppKit's own divider cursor rects off for chosen splits. A background deck entry's
/// split stays mounted at the full frame under opacity 0, and AppKit keeps its divider rect live there. The
/// visible terminal's per-move cursor masks it until a cover with no per-move writer, such as an ask, sits on
/// top; then the hidden column paints the resize cursor. SwiftUI owns the split's class and delegate, and the
/// delegate's effective rect also decides where a drag starts, so the hook is on `resetCursorRects`.
@MainActor
enum SplitCursorRects {
    nonisolated(unsafe) private static let suppressed = NSHashTable<NSSplitView>.weakObjects()
    private static var installed = false

    /// Sets whether `split` registers AppKit's divider cursor rects, rebuilding the ones it has now.
    static func setSuppressed(_ suppress: Bool, for split: NSSplitView) {
        installIfNeeded()
        guard suppress != suppressed.contains(split) else { return }
        if suppress { suppressed.add(split) } else { suppressed.remove(split) }
        split.window?.invalidateCursorRects(for: split)
    }

    /// Replaces NSSplitView's own `resetCursorRects` slot, adding one when the class only inherits NSView's,
    /// so every other view class keeps its implementation.
    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        let selector = #selector(NSView.resetCursorRects)
        guard let method = class_getInstanceMethod(NSSplitView.self, selector) else { return }
        let original = method_getImplementation(method)
        typealias Reset = @convention(c) (NSSplitView, Selector) -> Void
        let reset: @convention(block) (NSSplitView) -> Void = { split in
            guard suppressed.contains(split) else {
                unsafeBitCast(original, to: Reset.self)(split, selector)
                return
            }
            MainActor.assumeIsolated { split.discardCursorRects() }
        }
        let replacement = imp_implementationWithBlock(reset)
        if !class_addMethod(NSSplitView.self, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }
}
