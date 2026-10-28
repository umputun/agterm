import agtermCore
import AppKit

/// The row menu's Tint submenu: None and the fixed colors, then where the color shows. A batch of sessions
/// checks an entry only when every target shares it, and the placement entries act only on tinted rows.
extension WorkspaceSidebar.Coordinator {
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
            let item = NSMenuItem(title: color.rawValue.capitalized, action: #selector(menuTint(_:)), keyEquivalent: "")
            item.image = Self.swatch(color)
            item.state = colors == [color] ? .on : .off
            item.target = self
            item.representedObject = request(.color(color))
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(.sectionHeader(title: "Show On"))
        let allTinted = current.allSatisfy { $0 != nil }
        let placements = Set(current.map { $0.map { Set($0.parts) } })
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

    @objc private func menuTint(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? TintMenuRequest else { return }
        if let workspaceID = request.workspaceID {
            let current = store.workspaces.first { $0.id == workspaceID }?.tint
            store.setTint(request.choice.applied(to: current), forWorkspace: workspaceID)
            return
        }
        switch request.choice {
        case .color(let color): store.setTintColor(color, forSessions: request.sessionIDs)
        case .parts(let parts): store.setTintParts(parts, forSessions: request.sessionIDs)
        }
    }

    /// swatch draws at display time, so the dynamic system color follows the menu's appearance.
    private static func swatch(_ color: TintColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.tint(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// TintMenuRequest carries one menu choice and the rows it was built for, so it acts on exactly those.
    private final class TintMenuRequest {
        enum Choice {
            case color(TintColor?)
            case parts(Set<TintPart>)

            func applied(to current: SidebarTint?) -> SidebarTint? {
                switch self {
                case .color(let color): SidebarTint.recolor(current, to: color)
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
