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
        // latin layout: base letter is "c"
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "c", modifiers: [.control]))
        // dvorak: the C letter is a different physical key, caught by the character check
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.dvorakCKey, character: "c", modifiers: [.control]))
        // cyrillic: the physical C key produces "с" (U+0441), caught by the keyCode fallback
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "с", modifiers: [.control]))
        // no base char available: trust the physical key position
        #expect(InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: nil, modifiers: [.control]))
    }

    @Test func dvorakControlJDoesNotInterrupt() {
        // dvorak: the physical C key (keyCode 8) produces "j"; the keyCode fallback must NOT fire for a
        // latin letter other than "c", so ctrl-j is not a false interrupt
        #expect(!InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "j", modifiers: [.control]))
    }

    @Test func nonInterruptKeystrokesDoNotClear() {
        // ordinary typing, no control
        #expect(!InterruptKeystroke.isInterrupt(keyCode: Self.cKey, character: "c", modifiers: []))
        #expect(!InterruptKeystroke.isInterrupt(keyCode: 0, character: "a", modifiers: []))
        // control chords that are not an interrupt
        #expect(!InterruptKeystroke.isInterrupt(keyCode: 2, character: "d", modifiers: [.control]))   // ctrl-d
        // c with the wrong modifiers: cmd-c / opt-c / ctrl-cmd-c must not clear
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
