import AppKit
import ObjectiveC

/// The test bundle's principal class: XCTest builds one at bundle load, before any test runs.
/// Every window created in the hosted process from then on starts fully transparent, so the suite draws
/// nothing on screen while windows stay ordered in, key-eligible and visible to AppKit.
@objc(HostedWindowHider)
final class HostedWindowHider: NSObject {
    private typealias Initializer = @convention(c) (UnsafeRawPointer, Selector, NSRect, UInt, UInt, Bool) -> UnsafeRawPointer?

    private typealias Replacement = @convention(block) (UnsafeRawPointer, NSRect, UInt, UInt, Bool) -> UnsafeRawPointer?

    nonisolated(unsafe) private static var installed = false

    override init() {
        super.init()
        Self.install()
    }

    // raw pointers keep ARC out of an initializer, which consumes self and returns a retained object
    private static func install() {
        guard !installed else { return }
        installed = true
        let selector = NSSelectorFromString("initWithContentRect:styleMask:backing:defer:")
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let replacement: Replacement = { allocated, rect, style, backing, deferred in
            guard let made = original(allocated, selector, rect, style, backing, deferred) else { return nil }
            nonisolated(unsafe) let window = made
            MainActor.assumeIsolated { Unmanaged<NSWindow>.fromOpaque(window).takeUnretainedValue().alphaValue = 0 }
            return made
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
