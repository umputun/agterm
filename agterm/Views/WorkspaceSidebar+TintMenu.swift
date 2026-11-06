import agtermCore
import AppKit

/// The row menu's Tint submenu: None and the fixed colors, then where the color shows. A batch of sessions
/// checks an entry only when every target shares it, and the placement entries act only on tinted rows.
extension WorkspaceSidebar.Coordinator {
    /// tintPlacement is the last Show On pick, app-wide and in memory only. An untinted row shows it checked,
    /// and a color pick starts the row on it.
    static var tintPlacement: Set<TintPart> = [.icon]

    /// tintMenuItem builds the submenu for the menu's session targets.
    func tintMenuItem(forSessions ids: [UUID]) -> NSMenuItem {
        let tints = ids.map { store.session(withID: $0)?.tint }
        return tintMenuItem(current: tints, request: { TintMenuRequest(sessionIDs: ids, choice: $0) })
    }

    /// tintMenuItem builds the submenu for one workspace row's own tint.
    func tintMenuItem(forWorkspace id: UUID) -> NSMenuItem {
        let tint = store.workspaces.first { $0.id == id }?.tint
        return tintMenuItem(current: [tint], request: { TintMenuRequest(workspaceID: id, choice: $0) })
    }

    private func tintMenuItem(current: [SidebarTint?], request: (TintMenuRequest.Choice) -> TintMenuRequest) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let colors = Set(current.map { $0?.color })
        let none = NSMenuItem(title: "None", action: #selector(menuTint(_:)), keyEquivalent: "")
        none.state = colors == [nil] ? .on : .off
        none.target = self
        none.representedObject = request(.color(nil))
        submenu.addItem(none)
        for color in TintColor.allCases {
            let value = TintValue.named(color)
            submenu.addItem(colorItem(color.rawValue.capitalized, value, checked: colors == [value], request: request(.color(value))))
        }
        if colors.count == 1, case let .hex(hex)?? = colors.first {
            submenu.addItem(colorItem("Custom \(hex)", .hex(hex), checked: true, request: request(.color(.hex(hex)))))
        }
        submenu.addItem(.separator())
        submenu.addItem(.sectionHeader(title: "Show On"))
        let allTinted = current.allSatisfy { $0 != nil }
        let placements = Set(current.map { $0.map { Set($0.parts) } ?? Self.tintPlacement })
        let options: [(String, Set<TintPart>)] = [("Icon", [.icon]), ("Name", [.name]), ("Icon and Name", [.icon, .name])]
        for (title, parts) in options {
            let item = NSMenuItem(title: title, action: #selector(menuTint(_:)), keyEquivalent: "")
            item.isEnabled = allTinted
            item.state = placements == [parts] ? .on : .off
            item.target = self
            item.representedObject = request(.parts(parts))
            submenu.addItem(item)
        }
        let tint = NSMenuItem(title: "Tint", action: nil, keyEquivalent: "")
        tint.submenu = submenu
        return tint
    }

    /// colorItem is one swatched color row. macOS 27 can hide menu item images by default, so the swatch asks to stay.
    private func colorItem(_ title: String, _ value: TintValue, checked: Bool, request: TintMenuRequest) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuTint(_:)), keyEquivalent: "")
        item.image = Self.swatch(value)
        // preferredImageVisibility is macOS 27 SDK API the CI toolchain cannot name, so it is set by key; 1 is .visible
        if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
            item.setValue(1, forKey: "preferredImageVisibility")
        }
        item.state = checked ? .on : .off
        item.target = self
        item.representedObject = request
        return item
    }

    @objc private func menuTint(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? TintMenuRequest else { return }
        if case .parts(let parts) = request.choice {
            Self.tintPlacement = parts
        }
        if let workspaceID = request.workspaceID {
            let current = store.workspaces.first { $0.id == workspaceID }?.tint
            store.setTint(request.choice.applied(to: current, startingOn: Self.tintPlacement), forWorkspace: workspaceID)
            return
        }
        switch request.choice {
        case .color(let value?): store.setTintColor(value, forSessions: request.sessionIDs, startingOn: Self.tintPlacement)
        case .color(nil): store.setTintColor(nil, forSessions: request.sessionIDs)
        case .parts(let parts): store.setTintParts(parts, forSessions: request.sessionIDs)
        }
    }

    /// swatch draws at display time, so the dynamic system color follows the menu's appearance.
    private static func swatch(_ color: TintValue) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.tint(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// TintMenuRequest carries one menu choice and the rows it was built for, so it acts on exactly those.
    private final class TintMenuRequest {
        enum Choice {
            case color(TintValue?)
            case parts(Set<TintPart>)

            func applied(to current: SidebarTint?, startingOn placement: Set<TintPart>) -> SidebarTint? {
                switch self {
                case .color(let value): value.map { SidebarTint.recolor(current, to: $0, startingOn: placement) }
                case .parts(let parts): SidebarTint.place(current, on: parts)
                }
            }
        }

        let sessionIDs: [UUID]
        let workspaceID: UUID?
        let choice: Choice

        init(sessionIDs: [UUID] = [], workspaceID: UUID? = nil, choice: Choice) {
            self.sessionIDs = sessionIDs
            self.workspaceID = workspaceID
            self.choice = choice
        }
    }
}
