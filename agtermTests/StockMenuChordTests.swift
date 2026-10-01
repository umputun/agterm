import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class StockMenuChordTests: XCTestCase {
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

    private func item(_ title: String, _ selector: String, key: String, mask: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        return item
    }

    private func ownItem(_ title: String, key: String, mask: NSEvent.ModifierFlags) -> NSMenuItem {
        item(title, "menuAction:", key: key, mask: mask)
    }

    private func menu(_ items: [NSMenuItem], title: String = "Edit") -> NSMenu {
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = submenu
        let main = NSMenu()
        main.addItem(top)
        return main
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
        AppDelegate.applyStockMenuChords(keymap(), in: menu.menu)

        assertOwnsCommandW(menu.ours, "Close Session should own ⌘W at its shipped default")
        assertNoChord(menu.stock, "the stock Close must not compete for ⌘W")
    }

    func testRecoversFromSwiftUIUnbindingOurItem() {
        let menu = makeFileMenu(oursKey: "", stockKey: "w")
        AppDelegate.applyStockMenuChords(keymap(), in: menu.menu)

        assertOwnsCommandW(menu.ours, "Close Session should get ⌘W back")
        assertNoChord(menu.stock, "the stock Close should have released ⌘W")
    }

    func testRebindingCloseSessionAwayHandsCommandWToTheStockClose() {
        let menu = makeFileMenu(oursKey: "e")
        AppDelegate.applyStockMenuChords(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "nothing of agterm's wants ⌘W, so the stock Close keeps it")
    }

    // the empty stock key is what a previous reconcile leaves behind while close_session held ⌘W.
    func testRebindingAwayRestoresAClearedStockChord() {
        let menu = makeFileMenu(oursKey: "e", stockKey: "")
        AppDelegate.applyStockMenuChords(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "a cleared stock chord must be restored once agterm stops wanting it")
    }

    // SwiftUI defers its rebuild to the next activation, so straight after a reload that rebound
    // close_session away our item still advertises ⌘W — leaving it would show ⌘W twice in the File menu.
    func testStaleOurChordIsClearedWhenTheStockCloseTakesCommandW() {
        let menu = makeFileMenu(oursKey: "w", stockKey: "")
        AppDelegate.applyStockMenuChords(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

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
        AppDelegate.applyStockMenuChords(keymap(overrides), in: menu.menu)

        assertNoChord(menu.stock, "new_session owns ⌘W, so the stock Close must not advertise it too")
        XCTAssertEqual(menu.ours.keyEquivalent, "e", "our item's own chord must be left alone")
    }

    // a File menu carrying neither chord yet, the shape a fresh SwiftUI build hands over.
    func testRebindingAwayFromABareMenuLeavesTheStockCloseItsChord() {
        let menu = makeFileMenu()
        AppDelegate.applyStockMenuChords(keymap([.closeSession: Chord(mods: [.command], key: "e")]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "the stock Close keeps ⌘W when no built-in claims it")
        assertNoChord(menu.ours, "an item whose action does not own ⌘W must not be given the chord")
    }

    // `map ctrl+a>w close_session` binds the leader through the key monitor and leaves the action with NO menu
    // chord at all — the one way `equivalent(for:)` answers nil for an action that ships one.
    func testCloseSessionUnboundByAMapLineHandsCommandWToTheStockClose() {
        let menu = makeFileMenu(oursKey: "w")
        AppDelegate.applyStockMenuChords(keymap(unbound: [.closeSession]), in: menu.menu)

        assertOwnsCommandW(menu.stock, "no built-in holds ⌘W, so the stock Close takes it back")
        assertNoChord(menu.ours, "our stale ⌘W must be released once the action carries no menu chord")
    }

    // repeated `keymap reload` flips are the reported workflow, so being correct on the first transition
    // alone is not enough.
    func testRepeatedFlipsKeepOwnershipConsistent() {
        let menu = makeFileMenu(oursKey: "w")
        let away = keymap([.closeSession: Chord(mods: [.command], key: "e")])
        for _ in 0..<3 {
            AppDelegate.applyStockMenuChords(away, in: menu.menu)
            assertOwnsCommandW(menu.stock, "rebound away: the stock Close holds ⌘W")
            assertNoChord(menu.ours, "rebound away: our item must not still advertise ⌘W")

            AppDelegate.applyStockMenuChords(keymap(), in: menu.menu)
            assertOwnsCommandW(menu.ours, "rebound back: Close Session holds ⌘W")
            assertNoChord(menu.stock, "rebound back: the stock Close must release ⌘W")
        }
    }

    func testMenuWithoutBothItemsIsLeftAlone() {
        let lone = NSMenuItem(title: "Something Else", action: nil, keyEquivalent: "w")
        lone.keyEquivalentModifierMask = .command
        AppDelegate.applyStockMenuChords(keymap(), in: menu([lone], title: "View"))

        assertOwnsCommandW(lone, "an unrelated menu must not be rewritten")
    }

    func testClaimedStockChordIsClearedAndKeepsItsMask() {
        let closeAll = item("Close All", "closeAll:", key: "w", mask: [.command, .option])
        closeAll.isAlternate = true
        let main = menu([closeAll], title: "File")
        AppDelegate.applyStockMenuChords(keymap([.focusWorkspace: Chord(mods: [.command, .option], key: "w")]), in: main)

        assertNoChord(closeAll, "focus_workspace owns ⌥⌘W, so Close All must not dispatch it")
        XCTAssertEqual(closeAll.keyEquivalentModifierMask, [.command, .option], "the mask identifies the item on restore")
    }

    func testReleasedStockChordIsRestored() {
        let closeAll = item("Close All", "closeAll:", key: "", mask: [.command, .option])
        AppDelegate.applyStockMenuChords(keymap(), in: menu([closeAll], title: "File"))

        XCTAssertEqual(closeAll.keyEquivalent, "w", "no built-in holds ⌥⌘W, so Close All takes it back")
    }

    // regression: a rebuild between claim and release left our item on the freed ⌘V, and paste stopped working.
    func testStaleOwnCarrierIsClearedAndTheStockChordRestored() {
        let paste = item("Paste", "paste:", key: "", mask: .command)
        let split = ownItem("Toggle Vertical Split", key: "v", mask: .command)
        AppDelegate.applyStockMenuChords(keymap(), in: menu([paste, split]))

        assertNoChord(split, "our stale ⌘V must be released")
        XCTAssertEqual(paste.keyEquivalent, "v", "Paste takes ⌘V back")
    }

    func testStaleOwnCarrierIsClearedWhileTheStockItemIsAbsent() {
        let minimize = ownItem("Toggle Split", key: "m", mask: [.command, .option])
        AppDelegate.applyStockMenuChords(keymap(), in: menu([minimize], title: "Window"))

        assertNoChord(minimize, "Minimize All is inserted lazily, so our stale ⌥⌘M must go even without it")
    }

    func testUnmanagedItemKeepsAFreedStockChord() {
        let paste = item("Paste", "paste:", key: "", mask: .command)
        let service = item("Some Service", "someService:", key: "v", mask: .command)
        AppDelegate.applyStockMenuChords(keymap(), in: menu([paste, service]))

        XCTAssertEqual(service.keyEquivalent, "v", "only agterm's own items are ever cleared")
    }

    func testClaimingTheQuitAlternateLeavesThePrimaryQuit() {
        let quit = item("Quit Agterm", "terminate:", key: "q", mask: .command)
        let quitAll = item("Quit and Close All Windows", "terminate:", key: "q", mask: [.command, .option])
        quitAll.isAlternate = true
        AppDelegate.applyStockMenuChords(keymap([.focusWorkspace: Chord(mods: [.command, .option], key: "q")]),
                                         in: menu([quit, quitAll], title: "Agterm"))

        assertNoChord(quitAll, "focus_workspace owns ⌥⌘Q")
        XCTAssertEqual(quit.keyEquivalent, "q", "the primary Quit shares the selector but not the chord")
    }

    func testClaimingControlCommandSpaceLeavesThePaletteTwins() {
        let plain = item("Emoji & Symbols", "orderFrontCharacterPalette:", key: " ", mask: .command)
        let control = item("Emoji & Symbols", "orderFrontCharacterPalette:", key: " ", mask: [.control, .command])
        let globe = item("Emoji & Symbols", "orderFrontCharacterPalette:", key: "e", mask: .function)
        let globeControl = item("Emoji & Symbols", "orderFrontCharacterPalette:", key: " ", mask: [.function, .control, .command])
        AppDelegate.applyStockMenuChords(keymap([.focusWorkspace: Chord(mods: [.control, .command], key: "space")]),
                                         in: menu([plain, control, globe, globeControl]))

        assertNoChord(control, "focus_workspace owns ⌃⌘Space")
        XCTAssertEqual(plain.keyEquivalent, " ", "⌘Space is a different chord on the same selector")
        XCTAssertEqual(globe.keyEquivalent, "e", "fn+E has no keymap spelling and is never touched")
        XCTAssertEqual(globeControl.keyEquivalent, " ", "an fn mask never matches the claimed ⌃⌘Space entry")
    }

    func testRepeatedClaimAndReleaseAcrossARebuild() {
        let paste = item("Paste", "paste:", key: "v", mask: .command)
        let split = ownItem("Toggle Vertical Split", key: "d", mask: .command)
        let main = menu([paste, split])
        let claimed = keymap([.toggleSplit: Chord(mods: [.command], key: "v")])
        for _ in 0..<3 {
            AppDelegate.applyStockMenuChords(claimed, in: main)
            assertNoChord(paste, "claimed: Paste must not dispatch ⌘V")
            split.keyEquivalent = "v"

            AppDelegate.applyStockMenuChords(keymap(), in: main)
            XCTAssertEqual(paste.keyEquivalent, "v", "released: Paste holds ⌘V")
            assertNoChord(split, "released: our stale ⌘V is cleared")
            split.keyEquivalent = "d"
        }
    }

    func testNoShippedDefaultCollidesWithAStockChord() {
        let stock = Set(AppDelegate.stockMenuChords.map(\.chord))
        for action in BuiltinAction.allCases {
            guard let chord = keymap().equivalent(for: action) else { continue }
            XCTAssertFalse(stock.contains(chord), "\(action.rawValue) ships \(chord.displayString), a stock chord")
        }
    }
}
