import AppKit
import SwiftUI

/// The launch window's content while the app hosts unit tests: it makes its own window transparent.
struct HostedTestPlaceholder: NSViewRepresentable {
    func makeNSView(context _: Context) -> HostedTestPlaceholderView { HostedTestPlaceholderView() }

    func updateNSView(_: HostedTestPlaceholderView, context _: Context) {}
}

final class HostedTestPlaceholderView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // keep ordered in: ordering out the launch window exited the host before XCTest connected
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }
}
