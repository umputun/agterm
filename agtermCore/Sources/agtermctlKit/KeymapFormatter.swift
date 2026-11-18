import agtermCore

extension SocketClient {
    /// Render the `keymap.list` payload as sections: the resolved built-ins, then custom commands, `open` rules,
    /// parse diagnostics, and the live menu key equivalents (no trailing newline). An overridden built-in is
    /// marked `*`, a keyless one prints `-` rather than being dropped, so the listing is the full action set.
    /// The chord column carries the whole binding set joined with `|`: the menu key equivalent first, then the
    /// monitor-bound alternatives, each in canonical kitty syntax rather than the file's own spelling.
    ///
    /// The menu section is the point of the command: comparing it against the actions above is what shows
    /// a chord the keymap resolved but the menu is not carrying. Menu items print in menu-bar order.
    static func formatKeymap(_ keymap: ControlKeymap) -> String {
        var lines = ["keymap: \(keymap.path)", "", "actions:"]
        let width = keymap.actions.map(\.action.count).max() ?? 0
        for action in keymap.actions {
            let mark = action.overridden == true ? "*" : " "
            let name = action.action.padding(toLength: max(width, action.action.count), withPad: " ", startingAt: 0)
            let binds = ((action.chord.map { [$0] } ?? []) + (action.alternates ?? [])).joined(separator: "|")
            lines.append("  \(mark) \(name)  \(binds.isEmpty ? "-" : binds)\(action.repeats == true ? "  --repeat" : "")")
        }
        if !keymap.commands.isEmpty {
            lines.append(contentsOf: ["", "commands:"])
            lines.append(contentsOf: keymap.commands.map { command in
                var row = "    \(command.name)  \(command.shortcut ?? "(palette only)")"
                if command.repeats { row += "  --repeat" }
                if command.errorHud {
                    row += "  --error-hud --error-position \(command.errorPosition.rawValue)"
                    if let pane = command.errorPane { row += " --error-pane \(pane.rawValue)" }
                }
                return row
            })
        }
        if let openers = keymap.openers, !openers.isEmpty {
            lines.append(contentsOf: ["", "openers:"])
            lines.append(contentsOf: openers.map { "    \($0.selectors.joined(separator: ","))  \($0.command)" })
        }
        if !keymap.diagnostics.isEmpty {
            lines.append(contentsOf: ["", "diagnostics:"])
            // line 0 is the whole-file / cross-section sentinel, not a real line — drop the number
            // rather than sending the reader looking for it, matching SettingsView.diagnosticLine.
            lines.append(contentsOf: keymap.diagnostics.map {
                $0.line > 0 ? "    line \($0.line): \($0.message)" : "    \($0.message)"
            })
        }
        if let menu = keymap.menu {
            lines.append(contentsOf: ["", "menu:"])
            // mark a disabled item: its chord is inert (AppKit consumes the key and fires nothing, not
            // even a same-chord sibling), and the default non-JSON output is the documented human
            // workflow — an unmarked row reads as a live binding.
            lines.append(contentsOf: menu.map {
                "    \($0.chord)  \($0.menu) ▸ \($0.title)" + ($0.enabled == false ? "  (disabled)" : "")
            })
        }
        return lines.joined(separator: "\n")
    }
}
