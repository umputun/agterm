import AppKit
import CoreServices
import Quartz
import SwiftUI
import agtermCore

/// One live node in the file-tree panel's `NSOutlineView`: a file or directory under the session's root.
///
/// A reference type so `NSOutlineView` keeps stable per-item identity (expansion state survives a reload),
/// cached by absolute path in the `Coordinator`. Children are loaded lazily — a directory's contents are
/// read only when the outline first asks for them (on expand), so opening the panel never walks the whole
/// subtree. `@MainActor` because the whole panel (outline callbacks + `FileManager` reads) runs on the main
/// actor for MVP; moving enumeration off-main + FSEvents live-refresh is Phase 2.
@MainActor final class FileTreeNode {
    let url: URL
    let isDirectory: Bool
    /// The lazily-populated child cache; nil until the directory is first read.
    var loadedChildren: [FileTreeNode]?

    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

/// The file-tree panel: a right-hand `NSOutlineView` browsing a session's captured root directory. Mirrors
/// `WorkspaceSidebar`'s AppKit hosting (transparent `.plain` outline over the window backing, theme-pinned
/// disclosure triangle, terminal-foreground row text) so the two columns read as one system.
struct FileTreePanel: NSViewRepresentable {
    @Bindable var store: AppStore
    let actions: AppActions
    /// The absolute path the tree is rooted at (the session's `fileTreeRoot`). A change re-roots the outline.
    let rootPath: String
    /// A monotonically-bumped token (the session's `fileTreeRefreshToken`) that forces a re-read of the
    /// current root from disk even when `rootPath` is unchanged — the re-root/refresh button.
    let refreshToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(store: store, actions: actions) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileTreeOutlineView()
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.panelCoordinator = context.coordinator
        // double-click: a directory toggles expansion, a file opens in the default app.
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        outline.indentationPerLevel = 14
        outline.autosaveExpandedItems = false
        if #available(macOS 11.0, *) { outline.style = .plain }
        // .plain reverts backgroundColor to an opaque control color; clear it (like the sidebar) so the
        // transparent column shows the window backing through.
        outline.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        context.coordinator.outline = outline
        context.coordinator.applyThemeAppearance()
        context.coordinator.update(rootPath: rootPath, refreshToken: refreshToken)

        let scroll = NSScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier("agterm-filetree-scroll")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // re-root when the active session (or its root) changes; refresh when the token bumps; else no-op.
        context.coordinator.update(rootPath: rootPath, refreshToken: refreshToken)
        context.coordinator.applyThemeAppearance()
    }

    /// Data source + delegate for the outline. `@MainActor` so the AppKit callbacks satisfy the store's
    /// main-actor isolation, matching `WorkspaceSidebar.Coordinator`.
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let store: AppStore
        let actions: AppActions
        weak var outline: NSOutlineView?
        /// The current root directory node, or nil before the first `setRoot`.
        private var root: FileTreeNode?
        /// The path the outline is currently rooted at, to make `setRoot` idempotent across `updateNSView`.
        private var rootPath: String?
        /// Node cache keyed by absolute path, so a node's identity (and thus its expansion state) survives a
        /// reload — the file-tree analogue of the sidebar's `nodeCache`.
        private var nodeCache: [String: FileTreeNode] = [:]
        /// Whether dot-prefixed entries are shown. Hidden by default, like Finder.
        private let showHidden = false
        /// The last-applied refresh token, so a bump forces one re-read while an unchanged token is a no-op.
        private var lastRefreshToken = 0
        /// Debounce window collapsing an FS-event burst (a save, a branch switch, an `rm -rf`) into one
        /// `refresh()`. A calibration knob: real filesystems deliver events in bursts, so this is the tuning
        /// dial — same debounce family as the split-ratio save (0.4s) and theme preview (0.07s).
        private static let refreshDebounce: TimeInterval = 0.2
        /// The recursive FSEventStream watching the current root, or nil before the first `setRoot`.
        /// `nonisolated(unsafe)` so `deinit`/`stopWatching` can tear it down (like `SplitProbeView`).
        nonisolated(unsafe) private var eventStream: FSEventStreamRef?
        /// The pending debounced refresh, cancelled-and-rescheduled on every event burst.
        nonisolated(unsafe) private var refreshWorkItem: DispatchWorkItem?

        init(store: AppStore, actions: AppActions) {
            self.store = store
            self.actions = actions
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
                                                   name: .agtermAppearanceChanged, object: nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            refreshWorkItem?.cancel()
            stopWatching()
        }

        /// Applies the current `(rootPath, refreshToken)` from SwiftUI: a changed path re-roots, an unchanged
        /// path with a bumped token refreshes in place, and an unchanged pair is a no-op (so `updateNSView`
        /// firing for unrelated reasons doesn't blow away expansion/scroll state).
        func update(rootPath path: String, refreshToken token: Int) {
            if path != rootPath {
                setRoot(path)
            } else if token != lastRefreshToken {
                refresh()
            }
            lastRefreshToken = token
        }

        /// Roots the outline at `path` and reloads. Guarded idempotent on the path.
        func setRoot(_ path: String) {
            guard path != rootPath else { return }
            rootPath = path
            nodeCache.removeAll()
            let url = URL(fileURLWithPath: path)
            root = node(for: url, isDirectory: true)
            startWatching(url)
            outline?.reloadData()
        }

        /// Re-reads every loaded directory from disk (dropping the cached child arrays) and reloads, keeping
        /// the same root and — via the stable per-path node identity — the current expansion state. Backs the
        /// re-root/refresh button so it picks up files created/deleted since the panel opened.
        func refresh() {
            for node in nodeCache.values { node.loadedChildren = nil }
            outline?.reloadData()
        }

        // MARK: FSEvents live refresh

        // ponytail: FSEventStream recursive + full refresh(); per-dir kqueue or an incremental reloadItem-diff
        // if noise / large trees measurably slow this down.
        /// Arms a recursive FSEventStream on `url` (re-arming: any prior stream is stopped first), so files
        /// created/deleted/renamed anywhere under the root — including inside expanded subdirectories, which
        /// FSEvents covers for free — schedule a debounced `refresh()`. The C callback carries no context, so
        /// `self` rides across as an unretained `info` pointer (the stream never outlives the Coordinator: it
        /// is invalidated in `deinit`), and it hops to the main actor before touching any state.
        private func startWatching(_ url: URL) {
            stopWatching()
            // invariant: Coordinator is released on main (SwiftUI ownership) → callback + Invalidate are
            // serialized on the main queue, so the unretained `info` below is safe. A background strong-owner
            // of Coordinator would break that and open a UAF window.
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                let coordinator = Unmanaged<Coordinator>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async { coordinator.scheduleRefresh() }
            }
            // latency 0: deliver promptly; the DispatchWorkItem below is the single debounce knob.
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
            FSEventStreamSetDispatchQueue(stream, .main)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return
            }
            eventStream = stream
        }

        /// Stops and releases the current stream (idempotent). `nonisolated` so `deinit` can call it.
        nonisolated private func stopWatching() {
            guard let stream = eventStream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }

        /// Cancel-and-reschedule the debounced refresh so one event burst reads disk once, on the main actor.
        private func scheduleRefresh() {
            refreshWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            refreshWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDebounce, execute: work)
        }

        /// Open a file in the user's chosen editor .app (Settings ▸ General ▸ Open files with), falling back
        /// to the macOS default when unset OR when the chosen app no longer exists (trust boundary — never
        /// crash). Read on demand from the settings model, like `AppActions.confirmCloseSession`.
        private func openInEditor(_ url: URL) {
            if let appPath = actions.settingsModel?.settings.editorApp,
               FileManager.default.fileExists(atPath: appPath) {
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath),
                                        configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            } else {
                NSWorkspace.shared.open(url)  // system default / chosen app removed
            }
        }

        /// Double-click: a directory toggles its expansion, a file opens in the chosen editor (`openInEditor`).
        @objc func handleDoubleClick(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? FileTreeNode else { return }
            if node.isDirectory {
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            } else {
                openInEditor(node.url)
            }
        }

        /// Pins the outline appearance to the terminal theme's brightness so the disclosure triangle stays
        /// visible on a themed background (a light theme under macOS dark mode would otherwise draw an
        /// invisible triangle) — the same fix `WorkspaceSidebar` applies. Also reloads so row text re-tints.
        func applyThemeAppearance() {
            outline?.appearance = NSAppearance(named: GhosttyApp.shared.terminalThemeIsDark ? .darkAqua : .aqua)
        }

        @objc private func appearanceChanged() {
            applyThemeAppearance()
            outline?.reloadData()   // re-tint every visible row's text to the new theme foreground
        }

        // MARK: node building / lazy children

        private func node(for url: URL, isDirectory: Bool) -> FileTreeNode {
            let key = url.path
            if let existing = nodeCache[key] { return existing }
            let node = FileTreeNode(url: url, isDirectory: isDirectory)
            nodeCache[key] = node
            return node
        }

        private func children(of node: FileTreeNode) -> [FileTreeNode] {
            if let cached = node.loadedChildren { return cached }
            let loaded = loadChildren(of: node.url)
            node.loadedChildren = loaded
            return loaded
        }

        /// Reads one directory's contents, filters hidden entries and sorts them with the host-free
        /// `FileTreeOrder` (directories first, case-insensitive name), then wraps each in a cached node.
        private func loadChildren(of url: URL) -> [FileTreeNode] {
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: []) else { return [] }
            let entries = urls.map { childURL -> (URL, FileEntry) in
                let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return (childURL, FileEntry(name: childURL.lastPathComponent, isDirectory: isDir))
            }
            let visible = FileTreeOrder.filtered(entries.map(\.1), showHidden: showHidden)
            let byName = Dictionary(entries.map { ($0.1.name, $0.0) }, uniquingKeysWith: { first, _ in first })
            return FileTreeOrder.sorted(visible).compactMap { entry in
                byName[entry.name].map { node(for: $0, isDirectory: entry.isDirectory) }
            }
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = (item as? FileTreeNode) ?? root else { return 0 }
            guard node.isDirectory else { return 0 }
            return children(of: node).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let parent = (item as? FileTreeNode) ?? root
            return parent.map { children(of: $0)[index] } ?? FileTreeNode(url: URL(fileURLWithPath: "/"), isDirectory: true)
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileTreeNode)?.isDirectory ?? false
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileTreeNode else { return nil }
            let id = NSUserInterfaceItemIdentifier("file-tree-cell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? FileTreeCellView) ?? FileTreeCellView(identifier: id)
            cell.configure(name: node.name, icon: NSWorkspace.shared.icon(forFile: node.url.path),
                           textColor: GhosttyApp.shared.terminalForegroundColor ?? .labelColor)
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            // keep an open Quick Look preview in sync as the selection moves (arrow-nav while previewing).
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.reloadData()
            }
        }

        // MARK: context menu

        /// The right-click menu for a row: Open / Quick Look (files only), then Reveal in Finder / Copy Path
        /// / Insert Path (the path pasted at the active session's prompt).
        func contextMenu(forRow row: Int) -> NSMenu? {
            guard row >= 0, let node = outline?.item(atRow: row) as? FileTreeNode else { return nil }
            let menu = NSMenu()
            if !node.isDirectory {
                addItem(to: menu, "Open", #selector(menuOpen(_:)), node)
                addItem(to: menu, "Quick Look", #selector(menuQuickLook(_:)), node)
                menu.addItem(.separator())
            }
            addItem(to: menu, "Reveal in Finder", #selector(menuReveal(_:)), node)
            addItem(to: menu, "Copy Path", #selector(menuCopyPath(_:)), node)
            addItem(to: menu, "Insert Path", #selector(menuInsertPath(_:)), node)
            return menu
        }

        private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, _ node: FileTreeNode) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }

        @objc private func menuOpen(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileTreeNode else { return }
            openInEditor(node.url)
        }

        @objc private func menuQuickLook(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileTreeNode, let outline else { return }
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
            (outline as? FileTreeOutlineView)?.showQuickLook()
        }

        @objc private func menuReveal(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileTreeNode else { return }
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }

        @objc private func menuCopyPath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileTreeNode else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(node.url.path, forType: .string)
        }

        @objc private func menuInsertPath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileTreeNode else { return }
            actions.insertPath(node.url)
        }
    }
}

/// The file-tree outline. UNLIKE the sidebar's, it accepts first responder: clicking the tree focuses it so
/// arrow-key navigation and the Space-bar Quick Look gesture work (the terminal cursor just goes hollow
/// while the tree is focused, like any unfocused terminal). It is its own `QLPreviewPanel` controller, so
/// Space previews the selected file — the Finder gesture the user asked for.
final class FileTreeOutlineView: NSOutlineView, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    weak var panelCoordinator: FileTreePanel.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    /// The selected file's URL, or nil when nothing (or a directory) is selected — Quick Look previews files.
    private var selectedFileURL: URL? {
        guard selectedRow >= 0, let node = item(atRow: selectedRow) as? FileTreeNode, !node.isDirectory else { return nil }
        return node.url
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            toggleQuickLook()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Opens Quick Look for the current selection (from the context menu). No-op with nothing previewable.
    func showQuickLook() {
        guard selectedFileURL != nil, let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if selectedFileURL != nil {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return panelCoordinator?.contextMenu(forRow: row(at: point))
    }

    // MARK: QLPreviewPanel controller (this view is the controller in the responder chain)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedFileURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedFileURL as NSURL?
    }

    /// While Quick Look is open, forward ↑/↓ to the outline so the selection (and thus the preview) moves;
    /// let Space/Esc fall through to the panel's own close handling (the Finder toggle).
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126 else { return false }
        keyDown(with: event)   // 125 = down, 126 = up; not Space, so it hits NSOutlineView's selection nav
        return true
    }
}

/// A minimal icon + name row cell, laid out in code (no XIB), matching the sidebar's compact look.
final class FileTreeCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.cell?.usesSingleLineMode = true
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, icon iconImage: NSImage, textColor: NSColor) {
        iconImage.size = NSSize(width: 16, height: 16)
        icon.image = iconImage
        label.stringValue = name
        label.textColor = textColor
    }
}
