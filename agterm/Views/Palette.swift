import agtermCore
import AppKit
import SwiftUI

/// One selectable palette entry: a title, an optional subtitle (e.g. a session's cwd), and the closure to
/// run when chosen.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    /// The right-aligned shortcut hint, nil for items with no shortcut. Rebindable built-ins render the
    /// live keymap (`AppActions.shortcutGlyph`) as macOS menu glyphs (`⌘⇧E`), so they track rebinds; a
    /// custom command shows its raw kitty string (`cmd+shift+e`).
    let shortcut: String?
    /// A small trailing badge label (e.g. `custom` for user-defined keymap commands), nil for none.
    let badge: String?
    /// A leading agent-status glyph, nil for none — only the `.attention` palette sets it.
    let status: AgentStatus?
    /// Per-call `#rrggbb` tint for the status glyph (the session's `AgentIndicator.color`), so the
    /// attention row matches the sidebar; nil = the default status color.
    let statusColor: String?
    /// Per-call silhouette for the status glyph (`AgentIndicator.shape`); nil = the Settings shape.
    let statusShape: StatusShape?
    /// Fired when this item BECOMES the selection (keyboard navigation), distinct from `run` (Enter/click).
    /// Only `.themes` sets it, driving the live theme preview.
    let onSelect: (() -> Void)?
    let run: () -> Void

    init(id: String? = nil, title: String, subtitle: String? = nil, shortcut: String? = nil,
         badge: String? = nil, status: AgentStatus? = nil, statusColor: String? = nil,
         statusShape: StatusShape? = nil, onSelect: (() -> Void)? = nil, run: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.badge = badge
        self.status = status
        self.statusColor = statusColor
        self.statusShape = statusShape
        self.onSelect = onSelect
        self.run = run
    }
}

/// Which palette is open. Each fuzzy-searches its own source: `actions` the app's commands, `sessions` the
/// open sessions to jump between, `themes` the bundled themes with a live preview on navigation (Enter
/// commits, Esc reverts), `customCommands` the `custom` subset of `actions` shown without the badge.
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

    /// Open a palette unconditionally — the theme picker's launcher/menu item must not toggle `.themes`
    /// closed when it already happens to be the mode.
    func open(_ mode: PaletteMode) { self.mode = mode }

    func close() { mode = nil }
}

/// The palette overlay: a dimmed scrim (click to dismiss) over a top-centered search field and a
/// fuzzy-filtered result list. Type to filter, ↑/↓ to move, Enter to run, Esc to close. Mounted by
/// `ContentView` only while a palette is open.
struct CommandPalette: View {
    let controller: PaletteController
    let actions: AppActions
    /// Caller-provided rows for a control-API pick. A non-nil array replaces the built-in mode's
    /// catalog, including when the array is empty.
    let explicitItems: [PaletteItem]?
    /// Search-field prompt for an explicit picker; nil uses the neutral picker default.
    let prompt: String?
    /// Whether an unmatched, non-empty explicit-picker query can be submitted as free text.
    let allowCustom: Bool
    let onCustom: ((String) -> Void)?
    /// Called when an explicit picker is dismissed or completes. Built-in palettes leave this nil and
    /// continue to close through `PaletteController`; a pick uses it to resolve cancellation.
    let onDismiss: (() -> Void)?

    @State private var query: String
    @State private var selection = 0
    /// The visible, filtered result list. Held in `@State` so the rendered rows and the Enter target are
    /// one array — a computed property could be evaluated out of sync between the list and the handler.
    @State private var filtered: [PaletteItem] = []
    @FocusState private var fieldFocused: Bool

    /// `initialQuery` seeds the search field for an explicit picker: the caller's `--query` opens the
    /// palette already filtered, since `.onAppear` runs the first `updateFiltered()` against it.
    init(controller: PaletteController, actions: AppActions, items: [PaletteItem]? = nil,
         prompt: String? = nil, initialQuery: String? = nil, allowCustom: Bool = false,
         onCustom: ((String) -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.controller = controller
        self.actions = actions
        self.explicitItems = items
        self.prompt = prompt
        _query = State(initialValue: initialQuery ?? "")
        self.allowCustom = allowCustom
        self.onCustom = onCustom
        self.onDismiss = onDismiss
    }

    private var allItems: [PaletteItem] {
        if let explicitItems { return explicitItems }
        switch controller.mode {
        case .actions: return actions.paletteActions()
        case .sessions: return actions.paletteSessions()
        case .themes: return actions.paletteThemes()
        case .customCommands: return actions.paletteCustomCommands()
        case .attention: return actions.paletteAttention()
        case .none: return []
        }
    }

    /// Recomputes `filtered`: items whose search keys match (`paletteSearchKeys` — label only for a
    /// caller-supplied picker, label plus subtitle for a built-in palette), best score first then
    /// alphabetically by title so equal scores are ordered predictably. An empty query lists a built-in
    /// palette A→Z, but leaves a caller-supplied picker and `.attention` in their source order. The query is
    /// trimmed of whitespace AND newlines first: `fuzzyScore` splits on both, so a blank query that kept a
    /// newline would score every row 0 and lose the source order to the tie-break.
    private func updateFiltered() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // skipping the rank is what preserves the source order: every row scores 0 on an empty query and the
        // tie-break below would re-sort A→Z, replacing the intended first row — the one Return runs.
        if q.isEmpty, explicitItems != nil || controller.mode == .attention {
            filtered = allItems
            selection = filtered.isEmpty ? 0 : min(selection, filtered.count - 1)
            return
        }
        filtered = fuzzyRank(query: q, items: allItems) { item in
            paletteSearchKeys(title: item.title, subtitle: item.subtitle, callerSupplied: explicitItems != nil)
        }
        if explicitItems != nil,
           let label = pickCustomRowLabel(query: q, filteredCount: filtered.count, allowCustom: allowCustom) {
            filtered = [PaletteItem(id: "pick-custom", title: label) { onCustom?(q) }]
        }
        selection = filtered.isEmpty ? 0 : min(selection, filtered.count - 1)
    }

    private var placeholder: String {
        if explicitItems != nil { return prompt ?? "Select…" }
        switch controller.mode {
        case .sessions: return "Go to session…"
        case .themes: return "Select a theme…"
        case .customCommands: return "Run a custom command…"
        case .attention: return "Go to a session that needs attention…"
        default: return "Run an action…"
        }
    }

    /// Enter/leave the live-preview theme session as the palette opens, switches mode, or closes: entering
    /// `.themes` captures the current theme (so Esc can revert) and starts the selection on its row,
    /// leaving reverts any uncommitted preview. Idempotent — `AppActions` guards on its active flag.
    private func syncThemeSession() {
        guard explicitItems == nil, controller.mode == .themes else {
            actions.cancelThemePreview()
            return
        }
        actions.beginThemePreview()
        if let index = filtered.firstIndex(where: { $0.id == actions.currentThemeID }) { selection = index }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.2)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .accessibilityElement()
                    .accessibilityIdentifier(explicitItems == nil ? "palette-scrim" : "pick-scrim")
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
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(12)
            Divider()
            results
        }
        .background { PalettePanelBackground() }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
        .shadow(radius: 24)
        .accessibilityIdentifier(explicitItems == nil ? "command-palette" : "pick-palette")
        .onAppear {
            fieldFocused = true
            updateFiltered()
            if explicitItems == nil { syncThemeSession() }
            // a palette opened from a title-bar button (the attention bell) mounts while that button still
            // holds first responder, so the synchronous focus above loses the race. re-assert on the next
            // runloop tick, once the click settles; a no-op for the menu/hotkey/⌃P paths.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: controller.mode) {
            guard explicitItems == nil else { return }
            selection = 0
            updateFiltered()
            syncThemeSession()
        }
        .onDisappear {
            if explicitItems == nil { actions.cancelThemePreview() }
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isSelected: index == selection)
                            .id(item.id)
                            .onTapGesture { runItem(item) }
                    }
                }
            }
            .frame(maxHeight: 320)
            .onChange(of: selection) { _, sel in
                guard filtered.indices.contains(sel) else { return }
                filtered[sel].onSelect?()
                // with no anchor, scrollTo no-ops while the row is visible and does the minimum reveal at
                // an edge. an animated center-anchored scroll on every key-repeat kept interrupting
                // layout/compositing and made the material-backed palette flash.
                proxy.scrollTo(filtered[sel].id)
            }
        }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = max(0, min(selection + delta, filtered.count - 1))
    }

    /// Fires the selected item's `onSelect`. Called after a filter re-orders the list, so the new top match
    /// previews even when `selection` stayed 0 and `onChange(of: selection)` never fires.
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
        dismiss()
    }

    private func dismiss() {
        if explicitItems == nil { controller.close() }
        onDismiss?()
    }
}

/// A separate view type so a selection change in `CommandPalette` doesn't re-resolve the whole backdrop.
private struct PalettePanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder var body: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        }
    }
}

/// A real row view narrows SwiftUI's diffing boundary: a selection change updates the previous and next
/// rows instead of rebuilding every row helper in the lazy stack.
private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack {
            if let status = item.status {
                StatusGlyph(status: status, colorHex: item.statusColor, shape: item.statusShape)
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
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityIdentifier("palette-item-\(item.id)")
    }
}
