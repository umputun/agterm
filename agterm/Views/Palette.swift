import agtermCore
import SwiftUI

/// One selectable palette entry: a title (and optional subtitle, e.g. a session's cwd), an optional
/// keyboard-shortcut hint shown right-aligned, plus the closure to run when chosen.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    /// The action's keyboard shortcut hint shown right-aligned, nil for items with no shortcut.
    /// Rebindable built-ins read the live keymap (`AppActions.shortcutGlyph`) so it tracks rebinds and
    /// render as macOS menu glyphs (e.g. `⌘⇧E`); custom commands show their raw kitty shortcut string
    /// (e.g. `cmd+shift+e`). The six arrow-bound actions, not expressible as a `Chord`, keep their
    /// hardcoded glyph fallback.
    let shortcut: String?
    /// A small trailing badge label (e.g. `custom` for user-defined keymap commands), nil for none.
    let badge: String?
    /// A leading agent-status glyph (the attention palette's rows carry it), nil for items with no
    /// status — only the `.attention` palette sets it, so the other palettes render no glyph.
    let status: AgentStatus?
    /// Fired when this item BECOMES the selection (keyboard navigation), distinct from `run` (Enter/
    /// click). Only the `.themes` palette sets it — it drives the live theme preview; nil everywhere
    /// else, so the other palettes have no selection side effect.
    let onSelect: (() -> Void)?
    let run: () -> Void

    init(id: String? = nil, title: String, subtitle: String? = nil, shortcut: String? = nil,
         badge: String? = nil, status: AgentStatus? = nil, onSelect: (() -> Void)? = nil, run: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.badge = badge
        self.status = status
        self.onSelect = onSelect
        self.run = run
    }
}

/// Which palette is open. `actions` fuzzy-searches the app's commands; `sessions` fuzzy-searches
/// the open sessions to jump between them; `themes` fuzzy-searches the bundled themes with a live
/// preview on navigation (Enter commits, Esc reverts); `customCommands` fuzzy-searches only the
/// user-defined keymap commands (the `custom` subset of `actions`, shown without the badge).
enum PaletteMode {
    case actions
    case sessions
    case themes
    case customCommands
    case attention
}

/// Drives the command palettes: `mode` is nil when closed, else the open palette. App-global, set
/// by a toolbar/menu shortcut and observed by `ContentView` to mount the overlay.
@Observable
@MainActor
final class PaletteController {
    private(set) var mode: PaletteMode?

    /// Toggle a palette: the same shortcut again closes it; a different one switches.
    func toggle(_ mode: PaletteMode) {
        self.mode = (self.mode == mode) ? nil : mode
    }

    /// Open a specific palette unconditionally (used by the theme picker's launcher/menu item, which
    /// must open `.themes` rather than toggle it closed if it happened to already be the mode).
    func open(_ mode: PaletteMode) { self.mode = mode }

    func close() { mode = nil }
}

/// The palette overlay: a dimmed scrim (click to dismiss) with a top-centered search field and a
/// fuzzy-filtered result list. Type to filter, ↑/↓ to move, Enter to run, Esc to close. Mounted by
/// `ContentView` only while a palette is open; the item source switches on `controller.mode`.
struct CommandPalette: View {
    let controller: PaletteController
    let actions: AppActions

    @State private var query = ""
    @State private var selection = 0
    /// The visible, filtered result list. Held in `@State` (recomputed on query/mode change) so
    /// the rendered rows and the Enter target are guaranteed to be the same array — a recomputed
    /// property could otherwise be evaluated out of sync between the list and the run handler.
    @State private var filtered: [PaletteItem] = []
    @FocusState private var fieldFocused: Bool

    private var allItems: [PaletteItem] {
        switch controller.mode {
        case .actions: return actions.paletteActions()
        case .sessions: return actions.paletteSessions()
        case .themes: return actions.paletteThemes()
        case .customCommands: return actions.paletteCustomCommands()
        case .attention: return actions.paletteAttention()
        case .none: return []
        }
    }

    /// Recomputes `filtered` for the current query: keep items whose title (or subtitle) matches,
    /// best score first, then alphabetically by title (so an empty query lists everything A→Z and
    /// equal-scoring matches are ordered predictably).
    private func updateFiltered() {
        let q = query.trimmingCharacters(in: .whitespaces)
        // the attention palette's empty-query order is the paletteAttention()/attentionSessions ranking
        // (blocked→active→completed, newest change first). preserve it verbatim instead of falling through
        // to the alphabetical tie-break below — every row scores 0 for an empty query, so that tie-break
        // would re-sort them A→Z and Return would jump to the alphabetically-first session, not the blocked
        // one. fuzzy filtering still applies once the user types.
        if controller.mode == .attention, q.isEmpty {
            filtered = allItems
            selection = filtered.isEmpty ? 0 : min(selection, filtered.count - 1)
            return
        }
        let scored: [(item: PaletteItem, score: Int)] = allItems.compactMap { item in
            let scores = [fuzzyScore(query: q, target: item.title),
                          item.subtitle.flatMap { fuzzyScore(query: q, target: $0) }].compactMap { $0 }
            guard let best = scores.min() else { return nil }
            return (item, best)
        }
        filtered = scored.sorted {
            $0.score != $1.score
                ? $0.score < $1.score
                : $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
        }.map(\.item)
        selection = filtered.isEmpty ? 0 : min(selection, filtered.count - 1)
    }

    private var placeholder: String {
        switch controller.mode {
        case .sessions: return "Go to session…"
        case .themes: return "Select a theme…"
        case .customCommands: return "Run a custom command…"
        case .attention: return "Go to a session that needs attention…"
        default: return "Run an action…"
        }
    }

    /// Enter/leave the live-preview theme session as the palette opens, switches mode, or closes:
    /// entering `.themes` captures the current theme (so Esc can revert) and starts the selection on
    /// the current theme's row; leaving it (to another mode or closed) reverts any uncommitted preview.
    /// Idempotent — `AppActions` guards begin/cancel on its active flag.
    private func syncThemeSession() {
        guard controller.mode == .themes else { actions.cancelThemePreview(); return }
        actions.beginThemePreview()
        if let index = filtered.firstIndex(where: { $0.id == actions.currentThemeID }) { selection = index }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.2)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.close() }
                panel
                    .frame(width: 520)
                    .padding(.top, geo.size.height * 0.12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { runSelected() }
                    .onChange(of: query) { selection = 0; updateFiltered(); previewSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { controller.close(); return .handled }
            }
            .padding(12)
            Divider()
            results
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
        .shadow(radius: 24)
        .accessibilityIdentifier("command-palette")
        .onAppear {
            fieldFocused = true
            updateFiltered()
            syncThemeSession()
            // a palette opened from a title-bar button (the attention bell) mounts while that button
            // still holds first responder, so the synchronous focus above loses the race and the field
            // never takes the keyboard. re-assert on the next runloop tick — after the click settles —
            // so the field wins. for the menu/hotkey/⌃P paths the field is already focused by then, so
            // this is a no-op (see swiftui focus-pattern: onAppear focus may need a main-async kick).
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: controller.mode) { selection = 0; updateFiltered(); syncThemeSession() }
        .onDisappear { actions.cancelThemePreview() }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index)
                            .id(item.id)
                            .onTapGesture { runItem(item) }
                    }
                }
            }
            .frame(maxHeight: 320)
            .onChange(of: selection) { _, sel in
                guard filtered.indices.contains(sel) else { return }
                // live theme preview: navigating a row applies it (no-op for non-theme palettes,
                // whose items carry no onSelect).
                filtered[sel].onSelect?()
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(filtered[sel].id, anchor: .center) }
            }
        }
    }

    private func row(_ item: PaletteItem, index: Int) -> some View {
        HStack {
            if let status = item.status {
                StatusGlyph(status: status)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("palette-subtitle")
                        .accessibilityValue(subtitle)
                }
            }
            Spacer(minLength: 8)
            if let badge = item.badge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
                    .accessibilityIdentifier("palette-badge")
                    .accessibilityValue(badge)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == selection ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = max(0, min(selection + delta, filtered.count - 1))
    }

    /// Preview the currently-selected item (fires its `onSelect`). Called after a filter re-orders the
    /// list so the new top match previews even when `selection` stayed 0 (no `onChange(of: selection)`).
    /// A no-op for non-theme palettes — only theme rows carry an `onSelect`.
    private func previewSelected() {
        guard filtered.indices.contains(selection) else { return }
        filtered[selection].onSelect?()
    }

    private func runSelected() {
        guard filtered.indices.contains(selection) else { return }
        runItem(filtered[selection])
    }

    private func runItem(_ item: PaletteItem) {
        item.run()
        controller.close()
    }
}
