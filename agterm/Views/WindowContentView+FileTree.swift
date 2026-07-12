import agtermCore
import AppKit
import SwiftUI

/// The per-session file-tree panel on the RIGHT of the terminal: its draggable resize divider, the
/// column (top hairline + header + `NSOutlineView` panel), and the header strip (root name + re-root
/// button). Rendered inline inside `WindowContentView.splitRoot`; split out of `WindowContentView.swift`
/// to keep that file under the swiftlint size limit.
extension WindowContentView {
    /// A 1px themed vertical separator between the terminal and the file-tree panel — the file-tree twin of
    /// `sidebarDivider`, with the same wider invisible grab handle to drag-resize the panel. The panel is
    /// RIGHT-anchored (it hugs the window edge), so its width is the INVERSE of the sidebar's: the sidebar
    /// grows with the absolute cursor X (`cursor.x`), the file tree grows as the cursor moves LEFT, i.e.
    /// `totalWidth - cursor.x`, where `totalWidth` is the splitRoot width from the enclosing GeometryReader.
    func fileTreeDivider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(chromeText.opacity(0.1))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        // drive width from the absolute cursor X (window coords), NOT accumulated
                        // translation: the divider moves with the width, so translation-based resize feeds
                        // back on itself and the line flickers. Absolute position is stable. Inverted vs the
                        // sidebar because this panel is right-anchored: width = totalWidth - cursor.x.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                store.fileTreeWidth = min(AppStore.fileTreeWidthMax, max(AppStore.fileTreeWidthMin, Double(totalWidth - value.location.x)))
                            }
                            // persist the new width once, on release, not on every drag tick.
                            .onEnded { _ in store.save() }
                    )
            }
    }

    /// The file-tree column: a top hairline, a compact header (root name + refresh button), then the
    /// `NSOutlineView` panel — over the sidebar tint wash so it reads as one panel with the sidebar.
    func fileTreeColumn(for session: Session) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(chromeText.opacity(0.1))
                .frame(height: 1)
            fileTreeHeader(for: session)
            FileTreePanel(store: store, actions: actions,
                          rootPath: session.fileTreeRoot ?? session.effectiveCwd,
                          refreshToken: session.fileTreeRefreshToken)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .background(sidebarTintWash)
    }

    /// The file-tree header strip: the root directory's name and a button to re-root the tree to the
    /// session's current cwd (and re-read it).
    func fileTreeHeader(for session: Session) -> some View {
        let root = session.fileTreeRoot ?? session.effectiveCwd
        let name = (root as NSString).lastPathComponent
        return HStack(spacing: 4) {
            Image(systemName: "folder")
                .foregroundStyle(chromeText.opacity(0.7))
            Text(name.isEmpty ? "/" : name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(chromeText)
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            Button {
                actions.rerootFileTree()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(chromeText.opacity(0.7))
            .help("Refresh")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
