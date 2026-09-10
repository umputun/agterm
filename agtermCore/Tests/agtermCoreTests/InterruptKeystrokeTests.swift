import Testing
@testable import agtermCore

struct InterruptKeystrokeTests {
    private static let cKey = InterruptKeystroke.cKeyCode      // 8, physical C
    private static let escKey = InterruptKeystroke.escapeKeyCode // 53
    private static let dvorakCKey: UInt16 = 34                 // where the C letter sits on Dvorak

    @Test func escapeInterruptsUnderAnyModifiers() {
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.escKey, character: "\u{1b}", modifiers: []))
        // escape short-circuits before the modifier guard, so a modified escape still interrupts
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.escKey, character: "\u{1b}", modifiers: [.control]))
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.escKey, character: "\u{1b}", modifiers: [.command]))
    }

    @Test func bareControlCInterrupts() {
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "c", modifiers: [.control]))
        // dvorak: the C letter is a different physical key, caught by the character check
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.dvorakCKey, character: "c", modifiers: [.control]))
        // cyrillic: the physical C key produces "с" (U+0441), caught by the keyCode fallback
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "с", modifiers: [.control]))
        // no base char available: trust the physical key position
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: nil, modifiers: [.control]))
    }

    @Test func dvorakControlJDoesNotInterrupt() {
        // dvorak: the physical C key produces "j", and the keyCode fallback must not fire for another
        // latin letter
        #expect(!InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "j", modifiers: [.control]))
    }

    @Test func returnWithoutModifiersSubmits() {
        #expect(InterruptKeystroke.isSubmit(keyCode: InterruptKeystroke.returnKeyCode, modifiers: []))
        #expect(InterruptKeystroke.isSubmit(keyCode: InterruptKeystroke.keypadEnterKeyCode, modifiers: []))
        // shift-return and option-return insert a newline in claude code and codex
        #expect(!InterruptKeystroke.isSubmit(keyCode: InterruptKeystroke.returnKeyCode, modifiers: [.shift]))
        #expect(!InterruptKeystroke.isSubmit(keyCode: InterruptKeystroke.returnKeyCode, modifiers: [.option]))
        #expect(!InterruptKeystroke.isSubmit(keyCode: InterruptKeystroke.returnKeyCode, modifiers: [.command]))
        #expect(!InterruptKeystroke.isSubmit(keyCode: 0, modifiers: []))
    }

    @Test func classifyOrdersInterruptBeforeSubmitBeforeOther() {
        #expect(InterruptKeystroke.classify(keyCode: Self.escKey, character: "\u{1b}", modifiers: []) == .interrupt)
        #expect(InterruptKeystroke.classify(keyCode: Self.cKey, character: "c", modifiers: [.control]) == .interrupt)
        #expect(InterruptKeystroke.classify(keyCode: InterruptKeystroke.returnKeyCode, character: "\r", modifiers: []) == .submit)
        #expect(InterruptKeystroke.classify(keyCode: InterruptKeystroke.returnKeyCode, character: "\r", modifiers: [.shift]) == .other)
        #expect(InterruptKeystroke.classify(keyCode: 0, character: "a", modifiers: []) == .other)
    }

    @Test func classifyTextSubmitsOnlyWithANewline() {
        #expect(InterruptKeystroke.classify(text: "a") == .other)
        #expect(InterruptKeystroke.classify(text: "yes\n") == .submit)
        #expect(InterruptKeystroke.classify(text: "\r") == .submit)
        // crlf is a single character in swift, equal to neither lf nor cr
        #expect(InterruptKeystroke.classify(text: "yes\r\n") == .submit)
        #expect(InterruptKeystroke.classify(text: "\r\n") == .submit)
        #expect(InterruptKeystroke.classify(text: "a\u{2028}b") == .other)
        #expect(InterruptKeystroke.classify(text: "\u{1b}") == .other)
    }

    @Test func nonInterruptKeystrokesDoNotClear() {
        #expect(!InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "c", modifiers: []))
        #expect(!InterruptKeystroke.isInterrupt(keyCode: 0, character: "a", modifiers: []))
        #expect(!InterruptKeystroke.isInterrupt(keyCode: 2, character: "d", modifiers: [.control]))   // ctrl-d
        #expect(!InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "c", modifiers: [.command]))
        #expect(!InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "c", modifiers: [.option]))
        #expect(!InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "c", modifiers: [.control, .command]))
        // ctrl-shift-c: charactersIgnoringModifiers is "C"; shift is excluded so it must not clear
        #expect(!InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "C", modifiers: [.control, .shift]))
    }

    @Test func keyModifiersOptionSet() {
        let mods: KeyModifiers = [.control, .shift]
        #expect(mods.contains(.control))
        #expect(mods.contains(.shift))
        #expect(!mods.contains(.command))
        #expect(!mods.contains(.option))
    }
}
