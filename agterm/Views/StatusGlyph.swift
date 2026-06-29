import agtermCore
import SwiftUI

/// A small SF-Symbol agent-status glyph for the attention list — the status's `symbolName` tinted with
/// the configured status color, mirroring the sidebar's AppKit `StatusIconView`. Both surfaces draw from
/// the SAME mapping (`AgentStatus.symbolName` + `GhosttyApp.statusColor(for:)`) so they can't drift. Only
/// ever built for a non-idle status (idle has no symbol and is filtered out before any glyph is shown).
struct StatusGlyph: View {
    let status: AgentStatus

    var body: some View {
        Image(systemName: status.symbolName)
            .foregroundStyle(Color(nsColor: GhosttyApp.shared.statusColor(for: status)))
    }
}
