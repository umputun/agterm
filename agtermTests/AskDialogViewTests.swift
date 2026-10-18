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
        host.layoutSubtreeIfNeeded()
        let deadline = Date(timeIntervalSinceNow: 1)
        while fixture.catcher == nil, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        let catcher = try XCTUnwrap(fixture.catcher)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        terminal.onSearchEnd?()
        XCTAssertTrue(waitUntil { fixture.window.firstResponder === catcher },
                      "responder \(String(describing: fixture.window.firstResponder))")
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
            (124, [], .forward), (125, [], .down),
            (123, [], .backward), (126, [], .up), (49, [], .toggle),
            (36, [], .activate), (76, [], .activate), (53, [], .cancel),
        ]
        for (key, modifiers, expected) in cases {
            XCTAssertEqual(AskKeyCatcher.key(for: try event(key, modifiers: modifiers)), expected)
        }
    }

    func testUpAndDownStillMoveButtonsOfAPlainAsk() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let ask = PendingAsk(id: UUID().uuidString, title: "Pick", buttons: [ControlAskButton(id: "a", label: "A"),
                                                                            ControlAskButton(id: "b", label: "B")])
        XCTAssertTrue(fixture.session.openAsk(ask))
        XCTAssertTrue(AskRegistry.shared.register(id: ask.id, owner: .session(fixture.session.id, window: fixture.windowID)))
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        catcher.keyDown(with: try event(125))
        catcher.keyDown(with: try event(36, text: "\r"))
        XCTAssertEqual(AskRegistry.shared.result(for: ask.id)?.result.id, "b")
    }

    func testInputAskFocusesItsEditorAtOpenAndKeepsInputOwnership() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line, value: "draft")))
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        XCTAssertTrue(catcher.holds(editor))
        XCTAssertEqual(editor.string, "draft")
        XCTAssertTrue(catcher.canFocus)
        fixture.actions.resignDismissedFieldEditor(for: fixture.windowID)
        XCTAssertTrue(fixture.window.firstResponder === editor)
    }

    func testTypingUpdatesTheDraftAndReturnAnswersWithTheText() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line)))
        fixture.mount()
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        editor.insertText("hello world", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.session.askDraft?.text, "hello world")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result,
                       ControlAskResult(result: .answered, id: "ok", label: "OK", index: 0, text: "hello world"))
    }

    func testTabMovesTheHighlightToCancelWhichEscapesWithoutText() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line, value: "x")))
        fixture.mount()
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(fixture.window.firstResponder === editor)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result, ControlAskResult(result: .escaped))
    }

    func testEscInTheEditorEscapes() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line)))
        fixture.mount()
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result, ControlAskResult(result: .escaped))
    }

    func testMultilineReturnAddsALineAndCommandReturnAnswers() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .multiline)))
        fixture.mount()
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        let editor = try XCTUnwrap(fixture.window.firstResponder as? AskTextView)
        editor.insertText("one", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.insertText("two", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNotNil(fixture.session.askPending)
        XCTAssertFalse(editor.performKeyEquivalent(with: try event(36, text: "\r", modifiers: [.command, .shift])))
        XCTAssertTrue(editor.performKeyEquivalent(with: try event(36, text: "\r", modifiers: .command)))
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result.text, "one\ntwo")
    }

    func testCommandReturnDoesNothingWhileTheEditorIsNotFirstResponder() throws {
        let editor = AskTextView(frame: .zero)
        var submitted = false
        editor.onSubmit = { submitted = true }
        _ = editor.performKeyEquivalent(with: try event(36, text: "\r", modifiers: .command))
        XCTAssertFalse(submitted)
    }

    func testChoiceKeysMoveTheCursorToggleAndAnswerWithTheSelection() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let choices = [ControlAskChoice(id: "a", label: "A"), ControlAskChoice(id: "b", label: "B", subtitle: "two\nlines"),
                       ControlAskChoice(id: "c", label: "C")]
        try fixture.open(form: .choices(AskChoiceForm(choices: choices, multiple: true, checked: ["c"])))
        fixture.mount()
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        let catcher = try XCTUnwrap(fixture.catcher)
        XCTAssertTrue(fixture.window.firstResponder === catcher)
        catcher.keyDown(with: try event(126))
        catcher.keyDown(with: try event(49, text: " "))
        catcher.keyDown(with: try event(126))
        catcher.keyDown(with: try event(49, text: " "))
        XCTAssertEqual(fixture.session.askDraft?.selected, ["a", "b", "c"])
        catcher.keyDown(with: try event(36, text: "\r"))
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result.selected, ["a", "b", "c"])
    }

    func testALongListOpensScrolledToTheCheckedItem() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let choices = (1...50).map { ControlAskChoice(id: "i\($0)", label: "Item \($0)", subtitle: "one\ntwo\nthree") }
        try fixture.open(form: .choices(AskChoiceForm(choices: choices, multiple: false, checked: ["i50"])))
        fixture.mount()
        let host = try XCTUnwrap(fixture.window.contentView)
        func overflowingList() -> NSScrollView? {
            descendants(NSScrollView.self, in: host).first { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height }
        }
        func scrolledToEnd(_ list: NSScrollView) -> Bool {
            guard let document = list.documentView else { return false }
            let visible = list.documentVisibleRect
            let scrolled = document.isFlipped ? visible.minY > 0 : visible.maxY < document.frame.height
            let endVisible = document.isFlipped ? visible.maxY >= document.frame.height - 1 : visible.minY <= 1
            return visible.height > 0 && scrolled && endVisible
        }
        let settled = waitUntil { overflowingList().map(scrolledToEnd) == true }
        let list = try XCTUnwrap(overflowingList())
        let document = try XCTUnwrap(list.documentView)
        XCTAssertTrue(settled && scrolledToEnd(list), "visible \(list.documentVisibleRect) of document \(document.frame)")
    }

    func testTheDraftSurvivesTheDialogUnmountingAndComingBack() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line)))
        fixture.mount()
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        editor.insertText("kept", replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.window.contentView = nil
        fixture.mount()
        let remounted = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        XCTAssertEqual(remounted.string, "kept")
    }

    func testCommandWWithTheEditorFocusedDismissesTheAsk() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line)))
        fixture.mount()
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        XCTAssertTrue(fixture.window.firstResponder is NSTextView)
        XCTAssertTrue(fixture.actions.escapePendingSessionAsk())
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result, ControlAskResult(result: .escaped))
    }

    func testAnEditAtTheCapIsRefusedWithoutLosingTheEnd() throws {
        for mode in ControlAskInputMode.allCases {
            let fixture = try SessionAskTestFixture()
            defer { fixture.close() }
            let full = String(repeating: "x", count: AskInputForm.maxTextBytes - 1) + "Z"
            try fixture.open(form: .input(AskInputForm(mode: mode, value: full)))
            fixture.mount()
            let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText("A", replacementRange: NSRange(location: 0, length: 0))
            XCTAssertEqual(editor.string, full, "\(mode)")
            XCTAssertEqual(fixture.session.askDraft?.text, full, "\(mode)")
            editor.setSelectedRange(NSRange(location: 0, length: 1))
            editor.insertText("A", replacementRange: NSRange(location: 0, length: 1))
            XCTAssertEqual(fixture.session.askDraft?.text, "A" + full.dropFirst(), "\(mode)")
        }
    }

    func testAPasteWithAForbiddenControlIsRefusedWhole() throws {
        let cases: [(ControlAskInputMode, String, String)] = [
            (.line, "a\u{1}b", "kept"), (.line, "a\tb", "kept"), (.line, "a\nb", "kept"),
            (.multiline, "a\u{1}b", "kept"), (.multiline, "a\r\nb", "kept"), (.multiline, "a\u{7f}", "kept"),
            (.multiline, "a\tb\nc", "kepta\tb\nc"),
        ]
        for (mode, paste, expected) in cases {
            let fixture = try SessionAskTestFixture()
            defer { fixture.close() }
            try fixture.open(form: .input(AskInputForm(mode: mode, value: "kept")))
            fixture.mount()
            let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
            let end = NSRange(location: (editor.string as NSString).length, length: 0)
            editor.setSelectedRange(end)
            editor.insertText(paste, replacementRange: end)
            XCTAssertEqual(editor.string, expected, "\(mode) \(paste.debugDescription)")
            XCTAssertEqual(fixture.session.askDraft?.text, expected, "\(mode) \(paste.debugDescription)")
        }
    }

    func testACompositionThatWouldPassTheCapIsRefusedAndOneThatFitsCommits() throws {
        for mode in ControlAskInputMode.allCases {
            let fixture = try SessionAskTestFixture()
            defer { fixture.close() }
            let nearly = String(repeating: "x", count: AskInputForm.maxTextBytes - 2)
            try fixture.open(form: .input(AskInputForm(mode: mode, value: nearly)))
            fixture.mount()
            let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
            let end = NSRange(location: (editor.string as NSString).length, length: 0)
            editor.setSelectedRange(end)
            editor.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0), replacementRange: end)
            XCTAssertEqual(editor.string, nearly, "\(mode)")
            editor.setMarkedText("ab", selectedRange: NSRange(location: 2, length: 0), replacementRange: end)
            editor.insertText("ab", replacementRange: editor.markedRange())
            XCTAssertFalse(editor.hasMarkedText(), "\(mode)")
            XCTAssertEqual(editor.string, nearly + "ab", "\(mode)")
            XCTAssertEqual(fixture.session.askDraft?.text, nearly + "ab", "\(mode)")
        }
    }

    func testCommandWWhileAGUIAskEditorComposesKeepsTheAsk() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        let pick = PickController()
        PickRegistry.shared.register(fixture.windowID, controller: pick)
        let ask = PendingAsk(id: UUID().uuidString, title: "Name", buttons: [ControlAskButton(id: "ok", label: "OK")],
                             style: .gui, form: .input(AskInputForm(mode: .line)))
        XCTAssertTrue(pick.openAsk(ask))
        let host = NSHostingView(rootView: AskDialogView(
            ask: ask, anchorFrame: CGRect(x: 0, y: 0, width: 600, height: 300), font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            foreground: .white, background: .black, focusAllowed: true, draft: pick.askDraft,
            updateDraft: { pick.updateAskDraft(id: ask.id, $0) }, onAnswer: { pick.answerAsk(id: ask.id, buttonAt: $0) },
            onDismiss: { pick.escapeAsk() }
        ).frame(width: 600, height: 300))
        fixture.window.contentView = host
        fixture.window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        editor.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(fixture.actions.escapePendingAsk(for: fixture.windowID))
        XCTAssertEqual(pick.pendingAsk?.id, ask.id)
        editor.unmarkText()
        XCTAssertTrue(fixture.actions.escapePendingAsk(for: fixture.windowID))
        XCTAssertNil(pick.pendingAsk)
    }

    func testAWrappedParagraphGrowsTheMultilineEditor() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .multiline, value: "short")))
        fixture.mount()
        let host = try XCTUnwrap(fixture.window.contentView)
        let short = try XCTUnwrap(descendant(AskTextScrollView.self, in: host)).frame.height
        fixture.session.updateAskDraft(id: try XCTUnwrap(fixture.session.askPending?.id)) {
            $0.text = String(repeating: "wrapped words ", count: 120)
        }
        host.layoutSubtreeIfNeeded()
        let tall = try XCTUnwrap(descendant(AskTextScrollView.self, in: host)).frame.height
        XCTAssertGreaterThan(tall, short * 1.5)
    }

    func testCommandWWhileTheEditorComposesKeepsTheAsk() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line)))
        fixture.mount()
        let askID = try XCTUnwrap(fixture.session.askPending?.id)
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        editor.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(fixture.actions.escapePendingSessionAsk())
        XCTAssertEqual(fixture.session.askPending?.id, askID)
        editor.unmarkText()
        XCTAssertTrue(fixture.actions.escapePendingSessionAsk())
        XCTAssertEqual(AskRegistry.shared.result(for: askID)?.result, ControlAskResult(result: .escaped))
    }

    func testMultilineEditorGrowsWithItsLines() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .multiline, value: "one")))
        fixture.mount()
        let host = try XCTUnwrap(fixture.window.contentView)
        let short = try XCTUnwrap(descendant(AskTextScrollView.self, in: host)).frame.height
        fixture.session.updateAskDraft(id: try XCTUnwrap(fixture.session.askPending?.id)) {
            $0.text = (1...9).map(String.init).joined(separator: "\n")
        }
        host.layoutSubtreeIfNeeded()
        let tall = try XCTUnwrap(descendant(AskTextScrollView.self, in: host)).frame.height
        XCTAssertGreaterThan(tall, short * 1.5)
    }

    func testALayoutSwapHandsFocusAndTheDraftToTheReplacementEditor() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .multiline)))
        let tall = CGRect(x: 0, y: 0, width: 600, height: 300)
        let short = CGRect(x: 0, y: 0, width: 600, height: 110)
        let host = NSHostingView(rootView: AnyView(fixture.overlay(detail: tall).frame(width: 600, height: 300)))
        fixture.window.contentView = host
        fixture.window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        fixture.catcher?.updateFocus(revision: 1)
        let first = try XCTUnwrap(fixture.window.firstResponder as? AskTextView)
        first.insertText("kept", replacementRange: NSRange(location: NSNotFound, length: 0))

        host.rootView = AnyView(fixture.overlay(detail: short).frame(width: 600, height: 300))
        host.layoutSubtreeIfNeeded()
        let window = fixture.window
        let handedOver = waitUntil {
            guard let editor = window.firstResponder as? AskTextView else { return false }
            return editor !== first && editor === fixture.catcher?.editorBox?.focusTarget && editor.window === window
        }
        XCTAssertTrue(handedOver, "responder \(String(describing: window.firstResponder)), "
            + "focus target \(String(describing: fixture.catcher?.editorBox?.focusTarget))")
        let second = try XCTUnwrap(window.firstResponder as? AskTextView)
        XCTAssertFalse(second === first)
        XCTAssertEqual(second.string, "kept")
        XCTAssertEqual(fixture.session.askDraft?.text, "kept")
    }

    func testAReplacedEditorTakesFocusThatFellBackToTheWindow() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line)))
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        let box = try XCTUnwrap(catcher.editorBox)
        let host = try XCTUnwrap(fixture.window.contentView)
        fixture.window.makeFirstResponder(nil)
        let replacement = AskTextField(box: box)
        host.addSubview(replacement)
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        XCTAssertTrue((editor.delegate as AnyObject?) === replacement)
        replacement.removeFromSuperview()
    }

    func testAReplacedEditorLeavesAnUnrelatedFieldFocused() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line)))
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        let box = try XCTUnwrap(catcher.editorBox)
        let host = try XCTUnwrap(fixture.window.contentView)
        let other = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        host.addSubview(other)
        XCTAssertTrue(fixture.window.makeFirstResponder(other))
        let otherEditor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        let replacement = AskTextField(box: box)
        host.addSubview(replacement)
        XCTAssertTrue(fixture.window.firstResponder === otherEditor)
        replacement.removeFromSuperview()
    }

    func testAnUnrelatedFieldEditorStillTakesInputFromTheDialog() throws {
        let fixture = try SessionAskTestFixture()
        defer { fixture.close() }
        try fixture.open(form: .input(AskInputForm(mode: .line)))
        fixture.mount()
        let catcher = try XCTUnwrap(fixture.catcher)
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        fixture.window.contentView?.addSubview(field)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        XCTAssertFalse(catcher.holds(fixture.window.firstResponder))
        XCTAssertFalse(catcher.canFocus)
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

    /// Pumps the main run loop in short slices until `condition` holds or `timeout` passes; a focus handover or a
    /// scroll position lands a run-loop turn after layout, and a slow machine can take longer than a fixed pump.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return true
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
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

    func open(pane: OverlayPane? = nil, form: AskForm? = nil) throws {
        let buttons = form == nil ? [ControlAskButton(id: "yes", label: "Yes")]
            : [ControlAskButton(id: "ok", label: "OK"), ControlAskButton(id: "cancel", label: "Cancel")]
        let ask = PendingAsk(id: UUID().uuidString, title: "Continue?", buttons: buttons, defaultID: form == nil ? nil : "ok",
                             form: form, cancelID: form == nil ? nil : "cancel")
        let identity = pane.map { $0 == .left ? session.paneIdentity : session.splitPaneIdentity! }
        XCTAssertTrue(session.openAsk(ask, paneIdentity: identity))
        XCTAssertTrue(AskRegistry.shared.register(id: ask.id, owner: .session(session.id, window: windowID)))
    }

    func overlay(frames: HudPaneFrames? = nil, detail: CGRect = CGRect(x: 0, y: 0, width: 600, height: 300)) -> SessionAskOverlay {
        SessionAskOverlay(session: session, store: store, actions: actions, windowID: windowID,
                          detailFrame: detail,
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
