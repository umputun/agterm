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
    private var priorUsesUserKeyEquivalents = true

    // AppKit substitutes an App Shortcut from System Settings by menu-item TITLE the moment the item joins
    // a menu, replacing the key equivalent these tests set. "Close" and Close Session are both rebindable,
    // and both titles are load-bearing here, so the substitution is suppressed rather than the titles changed.
    override func setUp() {
        super.setUp()
        priorUsesUserKeyEquivalents = NSMenuItem.usesUserKeyEquivalents
        NSMenuItem.usesUserKeyEquivalents = false
    }

    override func tearDown() {
        NSMenuItem.usesUserKeyEquivalents = priorUsesUserKeyEquivalents
        super.tearDown()
    }

    private func keymap(_ overrides: [BuiltinAction: Chord] = [:], unbound: Set<BuiltinAction> = []) -> Keymap {
        Keymap(builtinOverrides: overrides, commands: [], builtinUnbound: unbound)
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

    // the empty stock key is what a previous reconcile leaves behind while close_session held ⌘W.
    func testRebindingAwayRestoresAClearedStockChord() {
        let menu = makeFileMenu(oursKey: "e", stockKey: "")
        AppDelegate.applyCloseSessionChord(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "a cleared stock chord must be restored once agterm stops wanting it")
    }

    // SwiftUI defers its rebuild to the next activation, so straight after a reload that rebound
    // close_session away our item still advertises ⌘W — leaving it would show ⌘W twice in the File menu.
    func testStaleOurChordIsClearedWhenTheStockCloseTakesCommandW() {
        let menu = makeFileMenu(oursKey: "w", stockKey: "")
        AppDelegate.applyCloseSessionChord(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertNoChord(menu.ours, "our stale ⌘W must be released when the stock Close takes the chord")
        assertOwnsCommandW(menu.stock, "the stock Close should hold ⌘W")
    }

    // `parseKeymap` rejects a chord only when two DISTINCT actions resolve to it, so moving close_session
    // off ⌘W frees the chord for any other built-in — stock ownership cannot be decided from it alone.
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

    // a File menu carrying neither chord yet, the shape a fresh SwiftUI build hands over.
    func testRebindingAwayFromABareMenuLeavesTheStockCloseItsChord() {
        let menu = makeFileMenu()
        AppDelegate.applyCloseSessionChord(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "the stock Close keeps ⌘W when no built-in claims it")
        assertNoChord(menu.ours, "an item whose action does not own ⌘W must not be given the chord")
    }

    // `map ctrl+a>w close_session` binds the leader through the key monitor and leaves the action with NO menu
    // chord at all — the one way `equivalent(for:)` answers nil for an action that ships one.
    func testCloseSessionUnboundByAMapLineHandsCommandWToTheStockClose() {
        let menu = makeFileMenu(oursKey: "w")
        AppDelegate.applyCloseSessionChord(keymap(unbound: [.closeSession]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "no built-in holds ⌘W, so the stock Close takes it back")
        assertNoChord(menu.ours, "our stale ⌘W must be released once the action carries no menu chord")
    }

    // repeated `keymap reload` flips are the reported workflow, so being correct on the first transition
    // alone is not enough.
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

    // the Edit/View menus go through the same walk, so a menu missing either half must be left alone.
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
