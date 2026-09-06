import AppKit
import SwiftUI
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AskDialogViewTests: XCTestCase {
    func testOverflowDialogRendersInNativeHost() throws {
        var selected: Int?
        let ask = PendingAsk(id: "overflow", title: "Choose an action",
                             message: "All six actions remain available in a small pane.",
                             buttons: (0..<6).map { ControlAskButton(id: "\($0)", label: "Action \($0)") })
        let view = AskDialogView(ask: ask, anchorFrame: CGRect(x: 565, y: 280, width: 335, height: 160),
                                 font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                 foreground: Color(white: 0.85), background: Color(white: 0.08),
                                 focusAllowed: true, onAnswer: { selected = $0 }, onDismiss: {})
            .frame(width: 900, height: 600)
            .background(Color(white: 0.15))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let catcher = try XCTUnwrap(window.firstResponder as? AskKeyCatcher.KeyCatcherView)
        catcher.keyDown(with: try event(36))
        XCTAssertNil(selected)
        catcher.keyDown(with: try event(48, modifiers: .shift))
        let scroll = try XCTUnwrap(descendant(NSScrollView.self, in: host))
        for _ in 0..<30 where scroll.contentView.bounds.minY == 0 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        catcher.keyDown(with: try event(36))
        XCTAssertEqual(selected, 5)
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        XCTAssertEqual(image.size, CGSize(width: 900, height: 600))
        XCTAssertGreaterThan(brightSamples(in: bitmap), 10)
        let attachment = XCTAttachment(image: image)
        attachment.name = "ask-native-overflow"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDialogRendersAtWindowPaneAndShortPaneSizes() throws {
        let ask = PendingAsk(id: "render", title: "Keep these changes?",
                             message: "Save this workspace, keep editing, or discard the current changes. Choose an action below.",
                             buttons: [ControlAskButton(id: "save", label: "Save workspace", hotkey: "s"),
                                       ControlAskButton(id: "cancel", label: "Keep editing", hotkey: "k"),
                                       ControlAskButton(id: "discard", label: "Discard changes", hotkey: "d")],
                             defaultID: "save", cancelID: "cancel", destructiveID: "discard")
        let frames = [
            ("wide", CGRect(x: 0, y: 30, width: 900, height: 570), ask),
            ("pane", CGRect(x: 565, y: 30, width: 335, height: 570), ask),
            ("short-pane", CGRect(x: 565, y: 280, width: 335, height: 220), ask),
        ]
        for (name, frame, question) in frames {
            let view = AskDialogView(ask: question, anchorFrame: frame, font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                     foreground: Color(white: 0.85), background: Color(white: 0.08),
                                     focusAllowed: false, onAnswer: { _ in }, onDismiss: {})
                .frame(width: 900, height: 600)
                .background(Color(white: 0.15))
            let renderer = ImageRenderer(content: view)
            let image = try XCTUnwrap(renderer.nsImage)
            XCTAssertEqual(image.size, CGSize(width: 900, height: 600))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            XCTAssertGreaterThan(brightSamples(in: bitmap), 10)
            let attachment = XCTAttachment(image: image)
            attachment.name = "ask-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testNavigationKeysMapToActions() throws {
        let cases: [(UInt16, NSEvent.ModifierFlags, AskKey)] = [
            (48, [], .forward), (48, .shift, .backward),
            (124, [], .forward), (125, [], .forward),
            (123, [], .backward), (126, [], .backward),
            (36, [], .activate), (76, [], .activate), (53, [], .cancel),
        ]
        for (key, modifiers, expected) in cases {
            XCTAssertEqual(AskKeyCatcher.key(for: try event(key, modifiers: modifiers)), expected)
        }
    }

    func testHotkeysFoldCaseAndIgnoreCommandControlOrOption() throws {
        XCTAssertEqual(AskKeyCatcher.key(for: try event(0, text: "A", modifiers: .shift)), .hotkey("a"))
        XCTAssertEqual(AskKeyCatcher.key(for: try event(0, text: "a")), .hotkey("a"))
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, [.shift, .command]] {
            XCTAssertNil(AskKeyCatcher.key(for: try event(0, text: "a", modifiers: modifiers)))
            XCTAssertNil(AskKeyCatcher.key(for: try event(36, modifiers: modifiers)))
        }
    }

    func testUnknownKeysDoNotProduceActions() throws {
        let view = AskKeyCatcher.KeyCatcherView()
        var actions: [AskKey] = []
        view.onKey = { actions.append($0) }
        for text in ["1", "!", "é", "", "\u{7f}"] {
            view.keyDown(with: try event(51, text: text))
        }
        XCTAssertTrue(actions.isEmpty)
        view.keyDown(with: try event(53))
        XCTAssertEqual(actions, [.cancel])
    }

    func testButtonLabelsShowDestructiveAndMissingLetterHotkey() throws {
        let destructive = AskDialogView.buttonLabel(ControlAskButton(id: "delete", label: "Delete", hotkey: "d"),
                                                    destructive: true)
        XCTAssertEqual(String(destructive.characters), "[ ! Delete ]")
        let letter = try XCTUnwrap(destructive.range(of: "D"))
        XCTAssertNotNil(destructive[letter].underlineStyle)
        let fallback = AskDialogView.buttonLabel(ControlAskButton(id: "save", label: "Save", hotkey: "x"),
                                                 destructive: false)
        XCTAssertEqual(String(fallback.characters), "[ Save (X) ]")
        let hint = try XCTUnwrap(fallback.range(of: "X"))
        XCTAssertNotNil(fallback[hint].underlineStyle)
    }

    private func event(_ keyCode: UInt16, text: String = "", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                      isARepeat: false, keyCode: keyCode))
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    private func brightSamples(in bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent > 0.65 {
                    count += 1
                }
            }
        }
        return count
    }
}
