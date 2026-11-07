import SwiftUI
import agtermCore

/// RemoteConnectionStrip is the line a remote window shows over its terminals while its catalog stream is not up.
struct RemoteConnectionStrip: View {
    let notice: String
    let refused: Bool
    let chromeText: Color
    let terminalColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: refused ? "exclamationmark.icloud" : "icloud.slash")
                .foregroundStyle(chromeText.opacity(0.7))
                .accessibilityHidden(true)
            Text(notice)
                .foregroundStyle(chromeText)
                .lineLimit(2)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(terminalColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(chromeText.opacity(0.15)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote-connection")
    }
}
