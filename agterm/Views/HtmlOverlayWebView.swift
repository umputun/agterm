import AppKit
import WebKit
import agtermCore

/// HtmlOverlayWebView reports focus and input to the model: a click on a pane page moves split focus like a
/// click on a pane program does, and typing counts as activity so auto-follow cannot switch sessions.
final class HtmlOverlayWebView: WKWebView {
    var pageID: UUID?
    var onFocus: (() -> Void)?
    var onClick: (() -> Void)?
    var onUserInput: (() -> Void)?
    var onDetach: (() -> Void)?
    private var parkedDragTypes: [NSPasteboard.PasteboardType] = []
    private var dropsEnabled = true

    /// setDropsEnabled keeps a page that is not on screen out of drag-destination lookup, which SwiftUI
    /// opacity does not do; a rejecting `draggingEntered` would still swallow the drop.
    func setDropsEnabled(_ enabled: Bool) {
        dropsEnabled = enabled
        if enabled {
            guard !parkedDragTypes.isEmpty else { return }
            registerForDraggedTypes(parkedDragTypes)
            parkedDragTypes = []
        } else if !registeredDraggedTypes.isEmpty {
            parkedDragTypes = registeredDraggedTypes
            unregisterDraggedTypes()
        }
    }

    // a web view answers AppKit's drag-destination lookup for any point in its frame, whatever types it has
    // registered, so parking them is not enough: an off-screen page declines here and AppKit moves on to the
    // views stacked beneath it; the selector is absent from the headers, so forwarding uses the base IMP
    @objc(_hitTest:dragTypes:) func dragDestination(at point: UnsafeMutablePointer<NSPoint>, types: NSSet) -> NSView? {
        let selector = #selector(dragDestination(at:types:))
        guard dropsEnabled, let method = class_getInstanceMethod(WKWebView.self, selector) else { return nil }
        typealias Lookup = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
        return unsafeBitCast(method_getImplementation(method), to: Lookup.self)(self, selector, point, types)
    }

    /// deferFocusToAsk hands the keyboard to a pending ask or picker that owns this page's slot, as a pane
    /// terminal does, and returns true when it did.
    func deferFocusToAsk(in session: Session) -> Bool {
        let pane = OverlayPane.allCases.first { session.paneOverlay($0)?.html?.id == pageID }
        guard GhosttySurfaceView.pickOwnsFocus(in: window, session: session, pane: pane) else { return false }
        AskKeyCatcher.KeyCatcherView.sessionCatchers.object(forKey: session.id as NSUUID)?.grabFocus()
        return true
    }

    var holdsFocus: Bool {
        (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onDetach?() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    // a dropped or pasted file reaches the page's script with its contents, so a drag or paste carrying files
    // is refused while text and links still go through; in a terminal the same paste gives only a path
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.carriesFiles(sender.draggingPasteboard) ? [] : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.carriesFiles(sender.draggingPasteboard) ? [] : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.carriesFiles(sender.draggingPasteboard) ? false : super.performDragOperation(sender)
    }

    // the paste selectors are absent from Swift's WKWebView interface, so forwarding uses the base IMP
    @objc(paste:) func pasteRefusingFiles(_ sender: Any?) {
        forwardPaste(#selector(pasteRefusingFiles(_:)), sender)
    }

    @objc(pasteAsPlainText:) func pasteAsPlainTextRefusingFiles(_ sender: Any?) {
        forwardPaste(#selector(pasteAsPlainTextRefusingFiles(_:)), sender)
    }

    @objc(readSelectionFromPasteboard:) func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let selector = #selector(readSelection(from:))
        guard !Self.carriesFiles(pasteboard), let method = class_getInstanceMethod(WKWebView.self, selector) else { return false }
        typealias Read = @convention(c) (AnyObject, Selector, NSPasteboard) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Read.self)(self, selector, pasteboard)
    }

    private func forwardPaste(_ selector: Selector, _ sender: Any?) {
        guard !Self.carriesFiles(.general), let method = class_getInstanceMethod(WKWebView.self, selector) else {
            return NSSound.beep()
        }
        typealias Paste = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(method_getImplementation(method), to: Paste.self)(self, selector, sender as AnyObject?)
    }

    private static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        let promises = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.types?.contains(where: promises.contains) == true
    }

    override func keyDown(with event: NSEvent) {
        onUserInput?()
        super.keyDown(with: event)
    }

    // an Esc the page leaves unhandled comes back from WebKit as cancelOperation: up the responder chain,
    // and the window's own handler takes a full-screen window out of full screen
    override func cancelOperation(_ sender: Any?) {}

    override func mouseDown(with event: NSEvent) {
        onUserInput?()
        onFocus?()
        onClick?()
        super.mouseDown(with: event)
    }
}
