import agtermCore
import AppKit
import SwiftUI

/// Title-bar custom-commands button and its popover, the mouse form of the ⌃⇧O palette (#570): every
/// `keymap.conf` command as a clickable row with its chord, the most-run ones grouped on top. Both groups
/// keep file order; usage changes only which commands sit in the top group. Split out of
/// `WindowContentView` like `+RecentSessions`, whose button it mirrors.
extension WindowContentView {
    /// How many most-run commands lead the list, and the command count above which that section appears.
    static let mostUsedCommandLimit = 5

    /// Title-bar button opening the custom-commands popover. Disabled/dimmed with no parsed command or no
    /// active session: the runner ignores a command fired without one, so every row would silently no-op.
    /// Opening a popover is interactive-only, so it is control-API keep-in-sync exempt like the clock and bell.
    var customCommandsButton: some View {
        let commands = actions.settingsModel?.keymap.commands ?? []
        let enabled = !commands.isEmpty && store.activeSession != nil && !pick.modalPending
        return Button {
            guard !pick.modalPending else { return }
            customCommandsShown.toggle()
        } label: {
            Label("Custom commands", systemImage: "ellipsis.circle")
        }
        .help(helpHint("Custom commands", .customCommandPalette))
        .foregroundStyle(chromeText)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityIdentifier("custom-commands-button")
        .popover(isPresented: $customCommandsShown, arrowEdge: .bottom) {
            customCommandsPopover(commands)
        }
        .onChange(of: customCommandsShown) { _, shown in
            // suppress auto-follow while open, counted like the clock and bell popovers so it stays balanced.
            if shown { store.suppressAutoFollow() } else { store.resumeAutoFollow() }
        }
        .onChange(of: enabled) { _, isEnabled in
            // a keymap reload emptying the list, or the last session exiting, fires no outside-click dismiss;
            // close so no sliver lingers under the now-disabled button.
            if !isEnabled { customCommandsShown = false }
        }
    }

    /// The popover body: the most-run commands (only once the keymap holds more than the limit) above a
    /// separator, then the rest, in a list that scrolls past a cap since the keymap has none, as wide as its
    /// longest row between a floor and the recent-sessions popover's width. Counts decide only which rows
    /// lead; both groups keep keymap order, so usage changes which commands sit on top and nothing else.
    /// Tinted like the recent-sessions popover. The counts are read on every open, so runs from a chord or
    /// the palette count too.
    private func customCommandsPopover(_ commands: [CustomCommand]) -> some View {
        let metrics = GhosttyApp.shared.interfaceMetrics
        let mostUsed = commands.count > Self.mostUsedCommandLimit
            ? actions.customCommandRunner?.usage.load().mostUsed(of: commands, limit: Self.mostUsedCommandLimit) ?? []
            : []
        let leadingIDs = Set(mostUsed.map(\.id))
        let leading = commands.filter { leadingIDs.contains($0.id) }
        let rest = commands.filter { !leadingIDs.contains($0.id) }
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(leading) { customCommandRow($0, accessibilityID: "custom-command-top-row") }
                if !leading.isEmpty {
                    Rectangle().fill(chromeText.opacity(0.25)).frame(height: 1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                ForEach(rest) { customCommandRow($0, accessibilityID: "custom-command-row") }
            }
            .padding(6)
        }
        .frame(width: CustomCommandPopoverRow.fittedWidth(for: commands, metrics: metrics))
        .frame(maxHeight: metrics.scaled(400))
        .background(terminalColor)
        .presentationBackground(terminalColor)
    }

    private func customCommandRow(_ command: CustomCommand, accessibilityID: String) -> some View {
        CustomCommandPopoverRow(title: command.name, shortcut: command.shortcut.isEmpty ? nil : command.shortcut,
                                foreground: chromeText, hoverColor: popoverHoverColor,
                                accessibilityID: accessibilityID) { runFromPopover(command) }
    }

    /// Commit a row click: note activity (so auto-follow can't pull the selection away), run the command
    /// through the palette's gate, return focus to the terminal and close the popover.
    private func runFromPopover(_ command: CustomCommand) {
        guard !pick.modalPending else { return }
        store.noteUserActivity()
        actions.runCustomCommand(command)
        actions.focusActiveSession()
        customCommandsShown = false
    }
}

/// One clickable command row for the custom-commands popover: the name at the palette's title size, the raw
/// kitty chord right-aligned like the palette's shortcut hint, a pointer-hover highlight and a full-row hit
/// area. Kept a `Button` so it reads as an actionable control to VoiceOver.
private struct CustomCommandPopoverRow: View {
    let title: String
    let shortcut: String?
    let foreground: Color
    let hoverColor: Color
    let accessibilityID: String
    let onSelect: () -> Void
    @State private var hovering = false
    private let metrics = GhosttyApp.shared.interfaceMetrics

    /// The gap between a name and its chord, and the row's side padding, shared with `fittedWidth`.
    private static let gap: CGFloat = 12
    private static let sidePadding: Double = 12

    /// The popover width that fits the widest row (name, gap, chord, paddings) between a floor and the
    /// recent-sessions popover's 320, measured with the row fonts so nothing truncates below the cap.
    static func fittedWidth(for commands: [CustomCommand], metrics: InterfaceMetrics) -> CGFloat {
        let title = NSFont.systemFont(ofSize: metrics.base)
        let chord = NSFont.systemFont(ofSize: metrics.shortcut)
        // each text is rounded up on its own, as SwiftUI lays it out; the spacer sits in every row, chord
        // or not, so its minimum always counts.
        let widest = commands.map { command -> CGFloat in
            var width = (command.name as NSString).size(withAttributes: [.font: title]).width.rounded(.up) + gap
            if !command.shortcut.isEmpty {
                width += (command.shortcut as NSString).size(withAttributes: [.font: chord]).width.rounded(.up)
            }
            return width
        }.max() ?? 0
        // the row's own side padding twice, plus the list's 6-point inset on each side.
        let chrome = CGFloat(metrics.scaled(sidePadding)) * 2 + 12
        return min(CGFloat(metrics.scaled(320)), max(CGFloat(metrics.scaled(180)), widest + chrome))
    }

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Text(title)
                    .font(.system(size: metrics.base))
                    .foregroundStyle(foreground)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Self.gap)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: metrics.shortcut))
                        .foregroundStyle(foreground.opacity(0.6))
                }
            }
            .padding(.horizontal, metrics.scaled(Self.sidePadding))
            .padding(.vertical, metrics.scaled(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? hoverColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(accessibilityID)
    }
}
