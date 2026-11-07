import SwiftUI
import agtermCore

/// RemoteConnectionStrip is a line a remote window shows over its terminals: its catalog stream is not up, or
/// actions whose outcome it could not learn, with the button that dismisses them.
struct RemoteConnectionStrip: View {
    let notice: String
    var symbol = "icloud.slash"
    var action: (title: String, run: () -> Void)?
    var identifier = "remote-connection"
    let chromeText: Color
    let terminalColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(chromeText.opacity(0.7))
                .accessibilityHidden(true)
            Text(notice)
                .foregroundStyle(chromeText)
                .lineLimit(2)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderless)
                    .foregroundStyle(chromeText)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(terminalColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(chromeText.opacity(0.15)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
