import AppKit
import SwiftUI
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AskDialogViewTests: XCTestCase {
    func testSearchEndReturnsItsEditorToPendingSessionAsk() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let services = agtermApp.SurfaceServices(library: fixture.library, actions: fixture.actions, zmxForegroundResolver: nil,
                                                 spawnRegistry: nil, launchContext: agtermApp.LaunchSpawnContext())
        let terminal = agtermApp.makeSurface(for: fixture.session, store: fixture.store, env: [:], services: services)
        defer { terminal.teardown() }
        fixture.session.surface = terminal
        terminal.onSearchStart?("needle")
        XCTAssertTrue(fixture.session.searchActive)
        let host = NSHostingView(rootView: SearchAndAskFixtureView(fixture: fixture, terminal: terminal).frame(width: 600, height: 300))
        fixture.window.contentView = host
        host.addSubview(terminal)
        fixture.window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(descendant(NSTextField.self, in: host))
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSText)
        try fixture.open()
        let deadline = Date(timeIntervalSinceNow: 1)
        while fixture.catcher == nil, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        let catcher = try XCTUnwrap(fixture.catcher)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        terminal.onSearchEnd?()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(fixture.session.searchActive)
        XCTAssertNil(fixture.session.searchSurface)
        XCTAssertTrue(fixture.window.firstResponder === catcher)
        catcher.keyDown(with: try event(36, text: "\r"))
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result.result, .answered)
    }

    func testSessionAskMountPreservesLiveFieldEditorUntilItResigns() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        fixture.window.contentView = container
        let field = NSTextField(frame: CGRect(x: 10, y: 260, width: 200, height: 24))
        container.addSubview(field)
        fixture.window.orderFront(nil)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSText)
        let ask = PendingAsk(id: UUID().uuidString, title: "Continue?",
                             buttons: [ControlAskButton(id: "yes", label: "Yes", hotkey: "y")])
        XCTAssertTrue(fixture.session.openAsk(ask))
        XCTAssertTrue(AskRegistry.shared.register(id: ask.id, owner: .session(fixture.session.id, window: fixture.windowID)))
        let host = NSHostingView(rootView: fixture.overlay().frame(width: 600, height: 300))
        host.frame = container.bounds
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let catcher = try XCTUnwrap(fixture.catcher)
        catcher.updateFocus(revision: 1)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertFalse(catcher.canFocus)
        catcher.keyDown(with: try event(16, text: "y"))
        XCTAssertEqual(fixture.session.askPending?.id, ask.id)
        fixture.window.makeFirstResponder(nil)
        catcher.updateFocus(revision: 2)
        XCTAssertTrue(fixture.window.firstResponder === catcher)
        catcher.keyDown(with: try event(16, text: "y"))
        XCTAssertEqual(AskRegistry.shared.result(for: ask.id)?.result.id, "yes")
    }

    func testSessionAskReclaimsInputWhenItsWindowBecomesKeyAgain() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open()
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        XCTAssertTrue(fixture.window.firstResponder === catcher)
        fixture.window.keyEligible = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        XCTAssertFalse(fixture.window.firstResponder === catcher)
        fixture.window.keyEligible = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        XCTAssertTrue(fixture.window.firstResponder === catcher)
    }

    func testSessionBackdropDoesNotPaintOutsideTheCoveredPane() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(pane: .right)
        let host = NSHostingView(rootView: fixture.overlay().frame(width: 600, height: 300).background(.white))
        fixture.window.contentView = host
        fixture.window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let left = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 8, y: bitmap.pixelsHigh / 8)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 7 / 8, y: bitmap.pixelsHigh / 8)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(left.redComponent, 0.95)
        XCTAssertLessThan(right.redComponent, left.redComponent - 0.1)
    }

    func testSessionAskMountHidesForCoversWithoutResolving() throws {
        for pane: OverlayPane? in [nil, .right] {
            let fixture = try SessionAskTestFixture()
            defer { fixture.close() }
            try fixture.open(pane: pane)
            let id = try XCTUnwrap(fixture.session.askPending?.id)
            fixture.mount()
            XCTAssertNotNil(fixture.catcher)
            fixture.session.scratchActive = true
            fixture.mount()
            XCTAssertEqual(fixture.catcher == nil, pane != nil)
            fixture.session.scratchActive = false
            let zoom = TerminalZoomController()
            TerminalZoomRegistry.shared.register(fixture.windowID, controller: zoom)
            zoom.set(.on, target: .session(fixture.session.id, .primary))
            fixture.mount()
            XCTAssertNil(fixture.catcher)
            zoom.clear()
            fixture.mount()
            XCTAssertNotNil(fixture.catcher)
            XCTAssertEqual(AskRegistry.shared.result(for: id)?.result.result, .pending)
        }
    }

    func testSessionAskMountUsesOnlyItsCoveredPaneAndReleasesFocus() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(pane: .right)
        fixture.session.splitFocused = true
        let overlay = fixture.overlay()
        XCTAssertEqual(overlay.coveredFrame, CGRect(x: 300, y: 0, width: 300, height: 300))
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        XCTAssertEqual(catcher.bounds.size, CGSize(width: 300, height: 300))
        XCTAssertEqual(catcher.convert(catcher.bounds, to: nil).minX, 300, accuracy: 1)
        catcher.updateFocus(revision: 1)
        XCTAssertTrue(fixture.window.firstResponder === catcher)
        fixture.session.splitFocused = false
        catcher.updateFocus(revision: 2)
        XCTAssertFalse(fixture.window.firstResponder === catcher)
        XCTAssertNotNil(fixture.session.askPending)
    }

    func testSessionAskWithoutPaneGeometryDoesNotMount() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(pane: .right)
        XCTAssertNil(fixture.overlay(frames: HudPaneFrames()).coveredFrame)
        fixture.mount(frames: HudPaneFrames())
        XCTAssertNil(fixture.catcher)
        XCTAssertNotNil(fixture.session.askPending)
    }

    func testSessionAskAnswerDoesNotTakeFocusFromAnUncoveredPane() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(pane: .right)
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 100, height: 24))
        fixture.window.contentView?.addSubview(field)
        fixture.window.makeFirstResponder(field)
        let responder = fixture.window.firstResponder
        let ask = try XCTUnwrap(fixture.session.askPending)
        fixture.session.resolveAsk(id: ask.id, ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0))
        catcher.updateFocus(revision: 1)
        XCTAssertTrue(fixture.window.firstResponder === responder)
        XCTAssertEqual(AskRegistry.shared.result(for: ask.id)?.result.result, .answered)
    }

    func testEqualButtonsRenderInBothLayoutsAndStyles() throws {
        for style in ControlAskStyle.allCases {
            for width: CGFloat in [700, 140] {
                let ask = PendingAsk(id: "equal-buttons", title: "Choose", buttons: [
                    ControlAskButton(id: "ok", label: "OK"), ControlAskButton(id: "cancel", label: "Cancel everything"),
                ], style: style)
                let view = AskDialogView(ask: ask, anchorFrame: CGRect(x: (700 - width) / 2, y: 0, width: width, height: 400),
                                         font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                         foreground: .white, background: .black, focusAllowed: false,
                                         onAnswer: { _ in }, onDismiss: {})
                    .frame(width: 700, height: 400)
                    .environment(\.colorScheme, .dark)
                    .environment(\.controlActiveState, .key)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 400),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.appearance = NSAppearance(named: .darkAqua)
                let host = NSHostingView(rootView: view)
                window.contentView = host
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(brightSamples(in: bitmap), 10)
                let image = NSImage(size: host.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "ask-equal-buttons-\(style.rawValue)-\(Int(width))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testSharedButtonWidthTakesTheWidestAndCapsAColumnAtTheProposal() {
        XCTAssertEqual(AskButtonLayout.sharedWidth(natural: [30, 120, 64], proposal: 500, axis: .horizontal), 120)
        XCTAssertEqual(AskButtonLayout.sharedWidth(natural: [30, 120, 64], proposal: nil, axis: .horizontal), 120)
        XCTAssertEqual(AskButtonLayout.sharedWidth(natural: [30, 120, 64], proposal: 90, axis: .horizontal), 120)
        XCTAssertEqual(AskButtonLayout.sharedWidth(natural: [30, 120, 64], proposal: 500, axis: .vertical), 120)
        XCTAssertEqual(AskButtonLayout.sharedWidth(natural: [30, 120, 64], proposal: 90, axis: .vertical), 90)
        XCTAssertEqual(AskButtonLayout.sharedWidth(natural: [30, 120, 64], proposal: nil, axis: .vertical), 120)
        XCTAssertEqual(AskButtonLayout.sharedWidth(natural: [], proposal: 90, axis: .horizontal), 0)
    }

    func testTerminalPanelFitsShortContentAndCapsLongLabelsInBothAppearances() throws {
        for dark in [false, true] {
            for long in [false, true] {
                let buttons = long
                    ? [ControlAskButton(id: "long", label: String(repeating: "A long button label ", count: 4))]
                    : [ControlAskButton(id: "yes", label: "Yes"), ControlAskButton(id: "no", label: "No")]
                let ask = PendingAsk(id: "sizing", title: "Continue?", message: "Choose.", buttons: buttons)
                let background: CGFloat = dark ? 0.08 : 0.95
                let view = AskDialogView(ask: ask, anchorFrame: CGRect(x: 50, y: 0, width: 300, height: 400),
                                         font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                         foreground: dark ? .white : .black, background: Color(white: background),
                                         focusAllowed: false, onAnswer: { _ in }, onDismiss: {})
                    .frame(width: 400, height: 400)
                    .background(Color(white: 0.5))
                let image = try XCTUnwrap(ImageRenderer(content: view).nsImage)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                let panelPixels = (0..<bitmap.pixelsWide).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return false }
                    return abs(color.redComponent - background) < 0.03
                }
                let width = try XCTUnwrap(panelPixels.last) - XCTUnwrap(panelPixels.first) + 1
                XCTAssertLessThanOrEqual(width, 270)
                if long {
                    XCTAssertGreaterThanOrEqual(width, 266)
                } else {
                    XCTAssertLessThan(width, 210)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "ask-sized-\(long ? "long" : "short")-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testBothStylesRenderInLightAndDarkAppearance() throws {
        for style in ControlAskStyle.allCases {
            for (dark, width) in [(false, Int?.none), (true, nil), (false, 50), (true, 50)] {
                let ask = PendingAsk(id: "appearance", title: "Keep these changes?", message: "Choose what happens next.",
                                     buttons: [ControlAskButton(id: "keep", label: "Keep", hotkey: "k"),
                                               ControlAskButton(id: "delete", label: "Delete", hotkey: "d")],
                                     defaultID: "keep", destructiveID: "delete", style: style, width: width)
                let view = AskDialogView(ask: ask, anchorFrame: CGRect(x: 0, y: 0, width: 700, height: 400),
                                         font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                                         foreground: dark ? .white : .black, background: dark ? .black : .white,
                                         focusAllowed: true, onAnswer: { _ in }, onDismiss: {})
                    .frame(width: 700, height: 400)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.controlActiveState, .key)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 400),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: view)
                window.contentView = host
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                XCTAssertTrue(window.firstResponder is AskKeyCatcher.KeyCatcherView)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(brightSamples(in: bitmap), 10)
                let image = NSImage(size: host.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "ask-\(style.rawValue)-\(dark ? "dark" : "light")-\(width == nil ? "auto" : "50-percent")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

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
        XCTAssertEqual(selected, 0)
        catcher.keyDown(with: try event(48, modifiers: .shift))
        let deadline = Date(timeIntervalSinceNow: 2)
        var scroll = try XCTUnwrap(descendant(NSScrollView.self, in: host))
        while scroll.contentView.bounds.minY == 0, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            scroll = try XCTUnwrap(descendant(NSScrollView.self, in: host))
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
                             defaultID: "save", destructiveID: "discard")
        let frames = [
            ("wide", CGRect(x: 0, y: 30, width: 900, height: 570), ask),
            ("pane", CGRect(x: 565, y: 30, width: 335, height: 570), ask),
            ("short-pane", CGRect(x: 565, y: 280, width: 335, height: 220), ask),
            ("long-label-terminal", CGRect(x: 565, y: 30, width: 335, height: 570),
             PendingAsk(id: "long-terminal", title: "Confirm", buttons: [ControlAskButton(id: "long", label: String(repeating: "A long button label ", count: 8))])),
            ("long-label-gui", CGRect(x: 565, y: 30, width: 335, height: 570),
             PendingAsk(id: "long-gui", title: "Confirm", buttons: [ControlAskButton(id: "long", label: String(repeating: "A long button label ", count: 8))], style: .gui)),
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
        XCTAssertEqual(String(destructive.characters), "! Delete")
        let letter = try XCTUnwrap(destructive.range(of: "D"))
        XCTAssertNotNil(destructive[letter].underlineStyle)
        let fallback = AskDialogView.buttonLabel(ControlAskButton(id: "save", label: "Save", hotkey: "x"),
                                                 destructive: false)
        XCTAssertEqual(String(fallback.characters), "Save (X)")
        let hint = try XCTUnwrap(fallback.range(of: "X"))
        XCTAssertNotNil(fallback[hint].underlineStyle)
        let plain = AskDialogView.buttonLabel(ControlAskButton(id: "yes", label: "Yes"), destructive: false)
        XCTAssertEqual(String(plain.characters), "Yes")
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

private struct SearchAndAskFixtureView: View {
    let fixture: SessionAskTestFixture
    let terminal: GhosttySurfaceView

    var body: some View {
        @Bindable var session = fixture.session
        ZStack(alignment: .topTrailing) {
            fixture.overlay()
            if session.searchActive {
                TerminalSearchBar(needle: $session.searchNeedle, displayText: "", onNext: {}, onPrevious: {},
                                  onClose: { terminal.onSearchEnd?() }, chromeText: .white, terminalColor: .black)
            }
        }
    }
}

@MainActor
final class SessionAskTestFixture {
    let library: WindowLibrary
    let store: AppStore
    let actions: AppActions
    let session: Session
    let windowID: UUID
    let window: SessionAskTestWindow
    private let directory: URL
    private let previousResolver: (AskRegistry.Owner) -> PendingAsk?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-focus-\(UUID().uuidString)")
        library = WindowLibrary(directory: directory)
        store = try XCTUnwrap(library.activeStore)
        session = try XCTUnwrap(store.activeSession)
        windowID = try XCTUnwrap(library.activeWindowID)
        actions = AppActions(library: library)
        session.hasSplit = true
        session.isSplit = true
        session.splitPaneIdentity = UUID()
        window = SessionAskTestWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(windowID, window: window)
        previousResolver = AskRegistry.shared.resolveOwner
        let store = store, previous = previousResolver
        AskRegistry.shared.resolveOwner = { owner in
            if case .session(let id, _) = owner, let session = store.session(withID: id) { return session.askPending }
            return previous(owner)
        }
    }

    var catcher: AskKeyCatcher.KeyCatcherView? {
        AskKeyCatcher.KeyCatcherView.sessionCatchers.object(forKey: session.id as NSUUID)
    }

    func open(pane: OverlayPane? = nil) throws {
        let ask = PendingAsk(id: UUID().uuidString, title: "Continue?", buttons: [ControlAskButton(id: "yes", label: "Yes")])
        let identity = pane.map { $0 == .left ? session.paneIdentity : session.splitPaneIdentity! }
        XCTAssertTrue(session.openAsk(ask, paneIdentity: identity))
        XCTAssertTrue(AskRegistry.shared.register(id: ask.id, owner: .session(session.id, window: windowID)))
    }

    func overlay(frames: HudPaneFrames? = nil) -> SessionAskOverlay {
        SessionAskOverlay(session: session, store: store, actions: actions, windowID: windowID,
                          detailFrame: CGRect(x: 0, y: 0, width: 600, height: 300),
                          paneFrames: frames ?? HudPaneFrames(left: HudPaneFrame(x: 0, y: 0, width: 300, height: 300),
                                                             right: HudPaneFrame(x: 300, y: 0, width: 300, height: 300)),
                          font: .monospacedSystemFont(ofSize: 13, weight: .regular), foreground: .white, background: .black)
    }

    func mount(frames: HudPaneFrames? = nil) {
        let host = NSHostingView(rootView: overlay(frames: frames).frame(width: 600, height: 300))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        catcher?.updateFocus(revision: 1)
    }

    func close() {
        session.cancelPendingAsk()
        catcher?.unregister()
        AskRegistry.shared.resolveOwner = previousResolver
        PickRegistry.shared.unregister(windowID)
        TerminalZoomRegistry.shared.unregister(windowID)
        DashboardControllerRegistry.shared.unregister(windowID)
        WindowRegistry.shared.unregister(windowID)
        window.contentView = nil
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Key eligibility is controlled here; the isolated Debug check verifies real window activation.
final class SessionAskTestWindow: NSWindow {
    var keyEligible = true
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { keyEligible }
}
