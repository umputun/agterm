import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Coverage for `AppDelegate.applyCloseSessionChord`, which decides whether ⌘W belongs to agterm's
/// File ▸ Close Session or to the stock `performClose:` item.
///
/// SwiftUI hands the stock item a ⌘W key equivalent as soon as agterm's own item vacates the chord, and
/// putting `close_session` back on ⌘W does not reclaim it — SwiftUI drops the shortcut from its OWN item
/// instead, leaving Close Session unbound and ⌘W closing the whole window until relaunch. These tests
/// drive the real `NSMenu` shapes the reconcile has to handle.
@MainActor
final class CloseSessionChordTests: XCTestCase {
    private let commandW = Chord(mods: [.command], key: "w")

    private func keymap(_ overrides: [BuiltinAction: Chord] = [:]) -> Keymap {
        Keymap(builtinOverrides: overrides, commands: [])
    }

    // A File menu shaped like the real one: agterm's Close Session (a SwiftUI closure button, so no
    // distinguishing selector) above the stock Close carrying `performClose:`.
    private func makeFileMenu(oursKey: String = "", stockKey: String = "") -> (menu: NSMenu, ours: NSMenuItem, stock: NSMenuItem) {
        let ours = NSMenuItem(title: AppDelegate.closeSessionItemTitle, action: nil, keyEquivalent: oursKey)
        if !oursKey.isEmpty { ours.keyEquivalentModifierMask = .command }
        let stock = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: stockKey)
        if !stockKey.isEmpty { stock.keyEquivalentModifierMask = .command }
        let submenu = NSMenu(title: "File")
        submenu.addItem(ours)
        submenu.addItem(stock)
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = submenu
        let main = NSMenu()
        main.addItem(fileItem)
        return (main, ours, stock)
    }

    private func assertOwnsCommandW(_ item: NSMenuItem, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(item.keyEquivalent, "w", message, file: file, line: line)
        XCTAssertEqual(item.keyEquivalentModifierMask, .command, message, file: file, line: line)
    }

    /// A menu item has no shortcut when its key equivalent is empty; the modifier mask alone is inert and
    /// AppKit defaults it to `.command` even for an item created with no key, so asserting on it would
    /// fail for items this reconcile never touches.
    private func assertNoChord(_ item: NSMenuItem, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(item.keyEquivalent, "", message, file: file, line: line)
    }

    func testDefaultKeymapGivesCommandWToCloseSessionAlone() {
        let menu = makeFileMenu(oursKey: "w")
        AppDelegate.applyCloseSessionChord(keymap(), in: menu.menu)

        assertOwnsCommandW(menu.ours, "Close Session should own ⌘W at its shipped default")
        assertNoChord(menu.stock, "the stock Close must not compete for ⌘W")
    }

    // the reported state: SwiftUI resolved the collision by unbinding its own item, so Close Session
    // carries NOTHING while the stock Close holds ⌘W. Reconcile has to undo exactly that.
    func testRecoversFromSwiftUIUnbindingOurItem() {
        let menu = makeFileMenu(oursKey: "", stockKey: "w")
        AppDelegate.applyCloseSessionChord(keymap(), in: menu.menu)

        assertOwnsCommandW(menu.ours, "Close Session should get ⌘W back")
        assertNoChord(menu.stock, "the stock Close should have released ⌘W")
    }

    func testRebindingCloseSessionAwayHandsCommandWToTheStockClose() {
        let menu = makeFileMenu(oursKey: "e")
        AppDelegate.applyCloseSessionChord(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "nothing of agterm's wants ⌘W, so the stock Close keeps it")
    }

    // a previous reconcile cleared the stock Close while close_session held ⌘W; rebinding away must hand
    // the chord back rather than leaving ⌘W dead.
    func testRebindingAwayRestoresAClearedStockChord() {
        let menu = makeFileMenu(oursKey: "e", stockKey: "")
        AppDelegate.applyCloseSessionChord(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "a cleared stock chord must be restored once agterm stops wanting it")
    }

    // SwiftUI defers its rebuild to the next activation, so straight after a reload that rebound
    // close_session away our item still advertises ⌘W. Arming the stock item without clearing that stale
    // one would leave the File menu showing ⌘W twice, one of them on the close-the-whole-window item.
    func testStaleOurChordIsClearedWhenTheStockCloseTakesCommandW() {
        let menu = makeFileMenu(oursKey: "w", stockKey: "")
        AppDelegate.applyCloseSessionChord(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertNoChord(menu.ours, "our stale ⌘W must be released when the stock Close takes the chord")
        assertOwnsCommandW(menu.stock, "the stock Close should hold ⌘W")
    }

    // `parseKeymap` rejects a chord only when two DISTINCT actions resolve to it, so moving close_session
    // off ⌘W frees the chord for any other built-in. Deciding stock ownership from close_session alone
    // would arm the stock item against a live built-in binding and re-create the reported failure.
    func testAnotherBuiltinOwningCommandWKeepsTheStockCloseBare() {
        let menu = makeFileMenu(oursKey: "e", stockKey: "w")
        let overrides: [BuiltinAction: Chord] = [
            .closeSession: Chord(mods: [.command], key: "e"),
            .newSession: commandW,
        ]
        AppDelegate.applyCloseSessionChord(keymap(overrides), in: menu.menu)

        assertNoChord(menu.stock, "new_session owns ⌘W, so the stock Close must not advertise it too")
        XCTAssertEqual(menu.ours.keyEquivalent, "e", "our item's own chord must be left alone")
    }

    func testUnboundCloseSessionLeavesTheStockCloseItsChord() {
        // close_session is keyless only if mapped to nothing; model that as another action taking its
        // default chord so `equivalent(for:)` no longer returns ⌘W for it.
        let menu = makeFileMenu()
        AppDelegate.applyCloseSessionChord(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "the stock Close keeps ⌘W when no built-in claims it")
        assertNoChord(menu.ours, "an item whose action does not own ⌘W must not be given the chord")
    }

    // repeated flips are the reported workflow (rebind away, rebind back, both via `keymap reload`), so
    // the reconcile has to be stable across them rather than correct only on the first transition.
    func testRepeatedFlipsKeepOwnershipConsistent() {
        let menu = makeFileMenu(oursKey: "w")
        let away = keymap([.closeSession: Chord(mods: [.command], key: "e")])
        for _ in 0..<3 {
            AppDelegate.applyCloseSessionChord(away, in: menu.menu)
            assertOwnsCommandW(menu.stock, "rebound away: the stock Close holds ⌘W")
            assertNoChord(menu.ours, "rebound away: our item must not still advertise ⌘W")

            AppDelegate.applyCloseSessionChord(keymap(), in: menu.menu)
            assertOwnsCommandW(menu.ours, "rebound back: Close Session holds ⌘W")
            assertNoChord(menu.stock, "rebound back: the stock Close must release ⌘W")
        }
    }

    // a menu missing either half (no `performClose:`, or no Close Session) must be left untouched rather
    // than half-reconciled — the Edit/View menus go through the same walk.
    func testMenuWithoutBothItemsIsLeftAlone() {
        let lone = NSMenuItem(title: "Something Else", action: nil, keyEquivalent: "w")
        lone.keyEquivalentModifierMask = .command
        let submenu = NSMenu(title: "View")
        submenu.addItem(lone)
        let top = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        top.submenu = submenu
        let main = NSMenu()
        main.addItem(top)

        AppDelegate.applyCloseSessionChord(keymap(), in: main)

        assertOwnsCommandW(lone, "an unrelated menu must not be rewritten")
    }
}
