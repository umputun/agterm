import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Coverage for the live-menu half of `keymap.list` — `ControlServer.collectKeyEquivalents`.
///
/// This half cannot be exercised end to end: agterm's own nested submenus (File ▸ Open Window, File ▸
/// Open Recent) carry no key equivalents, and App ▸ Services entries carry only the shortcuts a user
/// assigned in System Settings, so no nested chord exists for an XCUITest to assert against. These tests
/// build the menu shapes instead.
@MainActor
final class LiveMenuKeyEquivalentsTests: XCTestCase {
    private func item(_ title: String, key: String, mods: NSEvent.ModifierFlags = .command,
                      action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        // an item with no action is auto-disabled by AppKit unless autoenabling is off, so drive the
        // enabled state explicitly through the same flag the real menu ends up carrying.
        item.isEnabled = enabled
        return item
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    // the reason the recursion exists: AppKit's performKeyEquivalent recurses, so a chord one level down
    // is live and can shadow an agterm binding. Reporting only the top level would let a caller compare
    // the two lists and conclude nothing holds a chord when something does.
    func testCollectsKeyEquivalentsFromNestedSubmenus() {
        let nested = menu("Services", [item("Nested Service", key: "j", mods: [.command, .shift])])
        let parent = item("Services", key: "", action: nil)
        parent.submenu = nested
        let file = menu("File", [item("New Session", key: "n"), parent])

        let found = ControlServer.collectKeyEquivalents(in: file, menu: "File")

        XCTAssertEqual(found.map(\.chord), ["cmd+n", "cmd+shift+j"],
                       "a nested item's chord must be collected, not dropped at the first level")
        XCTAssertEqual(found.map(\.menu), ["File", "File"],
                       "a nested item stays attributed to the top-level menu the reader can find it under")
    }

    func testRecursesMoreThanOneLevelDeep() {
        let deepest = menu("Deeper", [item("Buried", key: "b")])
        let midItem = item("Deeper", key: "", action: nil)
        midItem.submenu = deepest
        let mid = menu("Nested", [midItem])
        let nestedItem = item("Nested", key: "", action: nil)
        nestedItem.submenu = mid
        let top = menu("File", [nestedItem])

        let found = ControlServer.collectKeyEquivalents(in: top, menu: "File")

        XCTAssertEqual(found.map(\.chord), ["cmd+b"], "the walk must not stop at a fixed depth")
    }

    func testItemsWithoutKeyEquivalentsAreSkipped() {
        let file = menu("File", [item("No Chord", key: ""), item("Has Chord", key: "n")])

        let found = ControlServer.collectKeyEquivalents(in: file, menu: "File")

        XCTAssertEqual(found.map(\.title), ["Has Chord"])
    }

    // a disabled item's chord is INERT — AppKit consumes the key equivalent and fires nothing, so a
    // caller comparing the two lists must be able to tell it apart from a live binding.
    func testDisabledItemsAreMarkedAndEnabledOnesAreNot() throws {
        let file = menu("File", [item("Live", key: "n"), item("Inert", key: "d", enabled: false)])

        let found = ControlServer.collectKeyEquivalents(in: file, menu: "File")

        XCTAssertNil(try XCTUnwrap(found.first { $0.title == "Live" }).enabled,
                     "an enabled item omits the flag rather than reporting true")
        XCTAssertEqual(try XCTUnwrap(found.first { $0.title == "Inert" }).enabled, false)
    }

    // AppKit matches an uppercase key equivalent against the SHIFTED chord even with shift absent from
    // the mask, so lowercasing without adding shift would name a chord the item can never fire.
    func testUppercaseKeyEquivalentReportsImpliedShift() throws {
        let file = menu("Edit", [item("Paste and Match Style", key: "V", mods: [.command, .option])])

        let found = try XCTUnwrap(ControlServer.collectKeyEquivalents(in: file, menu: "Edit").first)

        XCTAssertEqual(found.chord, "cmd+opt+shift+v")
    }

    // arrows and return arrive as function-key / control characters; rendering them raw would leave the
    // key missing and stop the chord comparing against the action list.
    func testNamedKeysRenderInKeymapVocabulary() {
        let file = menu("Navigate", [
            item("Previous Session", key: "\u{F700}", mods: [.command, .option]),
            item("Zoom", key: "\r", mods: [.command, .shift]),
        ])

        let found = ControlServer.collectKeyEquivalents(in: file, menu: "Navigate")

        XCTAssertEqual(found.map(\.chord), ["cmd+opt+up", "cmd+shift+return"])
    }

    func testSelectorIsReportedSoStockItemsAreDistinguishable() throws {
        let file = menu("File", [item("Close", key: "w", action: #selector(NSWindow.performClose(_:)))])

        let found = try XCTUnwrap(ControlServer.collectKeyEquivalents(in: file, menu: "File").first)

        XCTAssertEqual(found.selector, "performClose:", "a stock item is identified by its selector")
    }
}
